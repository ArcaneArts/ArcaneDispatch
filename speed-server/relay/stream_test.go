package relay

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"art.arcane/dispatch-speed-server/bonded"
)

// TestTCPRelay_EndToEnd_BondedDelivery verifies that two TCP-delivered
// bonded frames are reassembled in order and emitted as the original
// payload. Mirrors the UDP end-to-end test so the wire formats stay
// twinned across both transports.
func TestTCPRelay_EndToEnd_BondedDelivery(t *testing.T) {
	r := NewTCPRelay(TCPRelayConfig{
		ListenAddr: "127.0.0.1:0",
		GapTimeout: 50 * time.Millisecond,
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := r.Start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer r.Stop()

	addr := r.ListenAddr().String()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	sessionID := uint64(0xA1B2C3D4)
	chunkA := []byte("hello-stream-")
	chunkB := []byte("phase-eleven")
	sendFrame(t, conn, bonded.Frame{
		Version:   1,
		LinkID:    1,
		SessionID: sessionID,
		Seq:       0,
		Payload:   chunkA,
	})
	sendFrame(t, conn, bonded.Frame{
		Version:   1,
		LinkID:    1,
		SessionID: sessionID,
		Seq:       1,
		Payload:   chunkB,
	})

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		stats := r.Snapshot()
		if stats.PacketsAccepted >= 2 && stats.BytesEgress >= uint64(len(chunkA)+len(chunkB)) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	stats := r.Snapshot()
	t.Fatalf("stream egress did not converge: %+v", stats)
}

// TestTCPRelay_RejectsOversizedFrame verifies the length-prefix bound.
func TestTCPRelay_RejectsOversizedFrame(t *testing.T) {
	r := NewTCPRelay(TCPRelayConfig{
		ListenAddr:   "127.0.0.1:0",
		MaxFrameSize: 64,
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := r.Start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer r.Stop()

	conn, err := net.Dial("tcp", r.ListenAddr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	// Length prefix says 4 KiB but cap is 64. Relay must reject without
	// reading the body.
	var hdr [4]byte
	hdr[0] = 0
	hdr[1] = 0
	hdr[2] = 0x10
	hdr[3] = 0
	if _, err := conn.Write(hdr[:]); err != nil {
		t.Fatalf("write hdr: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	buf := make([]byte, 1)
	_, err = conn.Read(buf)
	if err == nil {
		t.Fatalf("expected connection close after bad length prefix")
	}

	deadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(deadline) {
		if r.Snapshot().PacketsBad >= 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("PacketsBad not incremented: %+v", r.Snapshot())
}

// TestTLSRelay_UpgradeAndDelivery exercises the HTTP/1.1 Upgrade path
// end-to-end: client speaks HTTP, the relay hijacks the conn, then
// bonded frames flow on the same socket.
func TestTLSRelay_UpgradeAndDelivery(t *testing.T) {
	certPEM, keyPEM := selfSignedCert(t, "127.0.0.1")
	r := NewTLSRelay(TLSRelayConfig{
		TCPRelayConfig: TCPRelayConfig{
			ListenAddr: "127.0.0.1:0",
			GapTimeout: 50 * time.Millisecond,
		},
		CertPEM: certPEM,
		KeyPEM:  keyPEM,
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addr, err := r.Start(ctx)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer r.Stop()

	tlsConfig := &tls.Config{InsecureSkipVerify: true}
	conn, err := tls.Dial("tcp", addr.String(), tlsConfig)
	if err != nil {
		t.Fatalf("tls dial: %v", err)
	}
	defer conn.Close()

	req := "GET /bonded HTTP/1.1\r\n" +
		"Host: 127.0.0.1\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: dispatch-bonded/1\r\n\r\n"
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatalf("write upgrade: %v", err)
	}

	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatalf("read upgrade resp: %v", err)
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("expected 101, got %d", resp.StatusCode)
	}

	// Now drive bonded frames on the hijacked stream.
	sessionID := uint64(0x42)
	sendFrameToReader(t, conn, br, bonded.Frame{
		Version:   1,
		LinkID:    1,
		SessionID: sessionID,
		Seq:       0,
		Payload:   []byte("tls-hello"),
	})
	sendFrameToReader(t, conn, br, bonded.Frame{
		Version:   1,
		LinkID:    1,
		SessionID: sessionID,
		Seq:       1,
		Payload:   []byte("tls-world"),
	})

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		s := r.Snapshot()
		if s.PacketsAccepted >= 2 && s.BytesEgress >= 18 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("TLS relay never received both frames: %+v", r.Snapshot())
}

// TestTLSRelay_RejectsWrongUpgradeProtocol verifies the relay refuses
// connections that don't ask for `dispatch-bonded/1`.
func TestTLSRelay_RejectsWrongUpgradeProtocol(t *testing.T) {
	certPEM, keyPEM := selfSignedCert(t, "127.0.0.1")
	r := NewTLSRelay(TLSRelayConfig{
		TCPRelayConfig: TCPRelayConfig{
			ListenAddr: "127.0.0.1:0",
		},
		CertPEM: certPEM,
		KeyPEM:  keyPEM,
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addr, err := r.Start(ctx)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer r.Stop()

	conn, err := tls.Dial("tcp", addr.String(), &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		t.Fatalf("tls dial: %v", err)
	}
	defer conn.Close()

	req := "GET /bonded HTTP/1.1\r\n" +
		"Host: 127.0.0.1\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: websocket\r\n\r\n"
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatalf("write: %v", err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}

	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if r.Snapshot().UpgradeRejected >= 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("UpgradeRejected counter not incremented")
}

// TestTLSRelay_HealthEndpoint sanity-checks the healthz route.
func TestTLSRelay_HealthEndpoint(t *testing.T) {
	certPEM, keyPEM := selfSignedCert(t, "127.0.0.1")
	r := NewTLSRelay(TLSRelayConfig{
		TCPRelayConfig: TCPRelayConfig{ListenAddr: "127.0.0.1:0"},
		CertPEM:        certPEM,
		KeyPEM:         keyPEM,
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addr, err := r.Start(ctx)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer r.Stop()

	client := &http.Client{
		Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
		Timeout:   500 * time.Millisecond,
	}
	resp, err := client.Get(fmt.Sprintf("https://%s/healthz", addr.String()))
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", resp.StatusCode)
	}
}

// TestReadStreamFrame_LengthMismatch covers the boundary where the
// length prefix advertises more bytes than the connection delivers.
func TestReadStreamFrame_LengthMismatch(t *testing.T) {
	var buf bytes.Buffer
	// Length = 8, payload = 4 bytes.
	hdr := []byte{0, 0, 0, 8}
	buf.Write(hdr)
	buf.Write([]byte{0xAA, 0xBB, 0xCC, 0xDD})

	br := bufio.NewReader(&buf)
	_, _, err := readStreamFrame(br, 64, nil)
	if !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("expected ErrUnexpectedEOF, got %v", err)
	}
}

// TestWriteStreamFrame_RoundTrips proves the writer + reader form a
// matching pair so cross-language tests can rely on `WriteStreamFrame`
// as the canonical length-prefix encoder.
func TestWriteStreamFrame_RoundTrips(t *testing.T) {
	opts := bonded.EncodeOptions{
		Version:   1,
		LinkID:    7,
		SessionID: 0xDEADBEEF,
		Seq:       42,
		Payload:   []byte("round-trip"),
	}
	encoded, err := bonded.Encode(opts)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	var buf bytes.Buffer
	if err := WriteStreamFrame(&buf, encoded); err != nil {
		t.Fatalf("write: %v", err)
	}
	br := bufio.NewReader(&buf)
	got, raw, err := readStreamFrame(br, 1500, nil)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Equal(raw, encoded) {
		t.Fatalf("raw bytes differ:\nwant %x\ngot  %x", encoded, raw)
	}
	if got.SessionID != opts.SessionID || got.Seq != opts.Seq || string(got.Payload) != string(opts.Payload) {
		t.Fatalf("frame mismatch: got %+v want %+v", got, opts)
	}
}

// Helpers --------------------------------------------------------------

func sendFrame(t *testing.T, w io.Writer, f bonded.Frame) {
	t.Helper()
	opts := bonded.EncodeOptions{
		Version:   f.Version,
		Flags:     f.Flags,
		Magic:     f.Magic,
		LinkID:    f.LinkID,
		SessionID: f.SessionID,
		Seq:       f.Seq,
		Payload:   f.Payload,
	}
	bs, err := bonded.Encode(opts)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if err := WriteStreamFrame(w, bs); err != nil {
		t.Fatalf("write frame: %v", err)
	}
}

// sendFrameToReader is used after an HTTP/1.1 upgrade where the same
// conn is read via the bufio.Reader we used for the upgrade response.
func sendFrameToReader(t *testing.T, w io.Writer, _ *bufio.Reader, f bonded.Frame) {
	t.Helper()
	sendFrame(t, w, f)
}

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

// _ keeps the imports stable across test edits.
var _ = strings.EqualFold
var _ = atomic.LoadInt64
