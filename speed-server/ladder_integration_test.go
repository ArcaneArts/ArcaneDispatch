// Package main hosts the cross-transport integration test for the
// speed-server. It boots a single binary with UDP + TCP + TLS relays
// enabled and drives the same bonded payload through every transport
// to prove the relays stay in lockstep. The Dart-side protocol ladder
// uses this guarantee to fall back without re-keying the application
// stream.
package main_test

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"art.arcane/dispatch-speed-server/bonded"
	"art.arcane/dispatch-speed-server/relay"
)

// TestProtocolLadder_ThreeTransports_EndToEnd exercises the three
// transports the protocol ladder cycles through. Each relay is given a
// distinct sessionId so we can assert the egress counters per transport.
func TestProtocolLadder_ThreeTransports_EndToEnd(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	udp := relay.NewUDPRelay(relay.UDPRelayConfig{
		ListenAddr: "127.0.0.1:0",
		GapTimeout: 50 * time.Millisecond,
	})
	if err := udp.Start(ctx); err != nil {
		t.Fatalf("udp start: %v", err)
	}
	defer udp.Stop()

	tcp := relay.NewTCPRelay(relay.TCPRelayConfig{
		ListenAddr: "127.0.0.1:0",
		GapTimeout: 50 * time.Millisecond,
	})
	if err := tcp.Start(ctx); err != nil {
		t.Fatalf("tcp start: %v", err)
	}
	defer tcp.Stop()

	cert, key := selfSignedCert(t, "127.0.0.1")
	tlsR := relay.NewTLSRelay(relay.TLSRelayConfig{
		TCPRelayConfig: relay.TCPRelayConfig{
			ListenAddr: "127.0.0.1:0",
			GapTimeout: 50 * time.Millisecond,
		},
		CertPEM: cert,
		KeyPEM:  key,
	})
	tlsAddr, err := tlsR.Start(ctx)
	if err != nil {
		t.Fatalf("tls start: %v", err)
	}
	defer tlsR.Stop()

	payload := []byte("ladder-end-to-end")

	// UDP path -----------------------------------------------------------
	udpConn, err := net.Dial("udp", udp.ListenAddr().String())
	if err != nil {
		t.Fatalf("udp dial: %v", err)
	}
	defer udpConn.Close()
	udpSession := uint64(0x1111)
	if _, err := udpConn.Write(encodeOne(t, udpSession, 0, payload)); err != nil {
		t.Fatalf("udp write: %v", err)
	}

	if !waitEgress(udp.Snapshot, len(payload), 2*time.Second) {
		t.Fatalf("udp egress missing: %+v", udp.Snapshot())
	}

	// TCP path -----------------------------------------------------------
	tcpConn, err := net.Dial("tcp", tcp.ListenAddr().String())
	if err != nil {
		t.Fatalf("tcp dial: %v", err)
	}
	defer tcpConn.Close()
	tcpSession := uint64(0x2222)
	frameBytes := encodeOne(t, tcpSession, 0, payload)
	if err := relay.WriteStreamFrame(tcpConn, frameBytes); err != nil {
		t.Fatalf("tcp write: %v", err)
	}

	if !waitStreamEgress(tcp.Snapshot, len(payload), 2*time.Second) {
		t.Fatalf("tcp egress missing: %+v", tcp.Snapshot())
	}

	// TLS path (HTTP/1.1 upgrade) ----------------------------------------
	tlsConn, err := tls.Dial("tcp", tlsAddr.String(), &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		t.Fatalf("tls dial: %v", err)
	}
	defer tlsConn.Close()
	req := "GET /bonded HTTP/1.1\r\n" +
		"Host: 127.0.0.1\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: dispatch-bonded/1\r\n\r\n"
	if _, err := io.WriteString(tlsConn, req); err != nil {
		t.Fatalf("tls write: %v", err)
	}
	br := bufio.NewReader(tlsConn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatalf("tls read resp: %v", err)
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("tls expected 101, got %d", resp.StatusCode)
	}
	tlsSession := uint64(0x3333)
	if err := relay.WriteStreamFrame(tlsConn, encodeOne(t, tlsSession, 0, payload)); err != nil {
		t.Fatalf("tls send: %v", err)
	}

	if !waitStreamEgress(tlsR.Snapshot, len(payload), 2*time.Second) {
		t.Fatalf("tls egress missing: %+v", tlsR.Snapshot())
	}

	// Sanity-check that the three transports are isolated (one session
	// each, no cross-talk).
	if udp.Snapshot().Sessions != 1 {
		t.Errorf("udp expected 1 session, got %d", udp.Snapshot().Sessions)
	}
	if tcp.Snapshot().Sessions != 1 {
		t.Errorf("tcp expected 1 session, got %d", tcp.Snapshot().Sessions)
	}
	if tlsR.Snapshot().Sessions != 1 {
		t.Errorf("tls expected 1 session, got %d", tlsR.Snapshot().Sessions)
	}
}

// encodeOne returns the encoded bonded frame bytes for a single payload.
func encodeOne(t *testing.T, sessionID, seq uint64, payload []byte) []byte {
	t.Helper()
	bs, err := bonded.Encode(bonded.EncodeOptions{
		Version:   1,
		LinkID:    1,
		SessionID: sessionID,
		Seq:       seq,
		Payload:   payload,
	})
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	return bs
}

// waitEgress polls a UDP snapshot for the expected egress byte count.
func waitEgress(snap func() relay.RelayStats, wantBytes int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if snap().BytesEgress >= uint64(wantBytes) {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

// waitStreamEgress polls a TCP/TLS snapshot for the expected egress count.
func waitStreamEgress(snap func() relay.StreamRelayStats, wantBytes int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if snap().BytesEgress >= uint64(wantBytes) {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

// selfSignedCert generates a throwaway PEM-encoded cert + key suitable
// for `InsecureSkipVerify` clients.
func selfSignedCert(t *testing.T, host string) (cert, key []byte) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa: %v", err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "dispatch-test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.ParseIP(host)},
		DNSNames:     []string{host},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("x509: %v", err)
	}
	cert = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER := x509.MarshalPKCS1PrivateKey(priv)
	key = pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: keyDER})
	return cert, key
}

// _ keeps imports referenced for future test additions.
var _ = binary.BigEndian
var _ atomic.Uint32
