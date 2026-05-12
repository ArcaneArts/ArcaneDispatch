// Package crypto holds the encryption layer for the bonded transport.
//
// We implement Noise_IK_25519_ChaChaPoly_SHA256 by hand (rather than
// pulling in `github.com/flynn/noise`) for three reasons:
//
//   1. The cross-language story is much cleaner — we control every
//      detail of the wire format so the Dart and Swift mirrors can match
//      byte-for-byte against the same vector tests.
//   2. We only need the IK pattern (one round-trip, client knows the
//      server's static pubkey ahead of time). A general-purpose Noise
//      lib adds a meaningful amount of code we never exercise.
//   3. The hand-written state machine is < 250 LOC and easy to audit.
//
// The Noise spec we conform to: https://noiseprotocol.org/noise.html r34.
// Protocol name: "Noise_IK_25519_ChaChaPoly_SHA256".
//
// Cipher: ChaCha20-Poly1305 with 8-byte AD nonces zero-padded to 12 B.
// Curve: X25519 (curve25519).
// Hash:  SHA-256.
// HKDF outputs 32-byte keys (we never need the 96-byte triple form, so
// the helper is hard-coded to two outputs).
package crypto

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
)

// ProtocolName is the exact ASCII string mixed into the initial chaining
// hash. Changing this string breaks wire compat with every other side —
// see the Noise spec §5 "h ← HASH(protocol_name)".
const ProtocolName = "Noise_IK_25519_ChaChaPoly_SHA256"

// MaxHandshakePayload caps user payloads inside handshake messages so the
// caller can't blow past the path MTU. Noise itself has no limit beyond
// 2^16 − 16 bytes; we pick a tight bound that matches our bonded frame
// budget.
const MaxHandshakePayload = 1024

// HandshakeRole records which side of an IK handshake we are.
type HandshakeRole int

const (
	// RoleInitiator is the client side (knows the responder's static key).
	RoleInitiator HandshakeRole = iota
	// RoleResponder is the server side (knows its own static key only).
	RoleResponder
)

// Keypair is an X25519 (private, public) pair. The private half is the
// raw 32-byte little-endian scalar; the public half is the corresponding
// point. We never persist the public separately — derive on demand.
type Keypair struct {
	Private [32]byte
	Public  [32]byte
}

// GenerateKeypair mints a fresh X25519 keypair. Reads 32 bytes from
// crypto/rand and runs the curve25519 base-point multiplication to
// derive the public half.
func GenerateKeypair() (Keypair, error) {
	var kp Keypair
	if _, err := io.ReadFull(rand.Reader, kp.Private[:]); err != nil {
		return Keypair{}, fmt.Errorf("crypto: generate keypair: %w", err)
	}
	curve25519.ScalarBaseMult(&kp.Public, &kp.Private)
	return kp, nil
}

// KeypairFromSeed deterministically derives a keypair from a 32-byte
// seed. Used by the test vectors so both sides can build the same
// keypair from a published seed.
func KeypairFromSeed(seed [32]byte) Keypair {
	var kp Keypair
	kp.Private = seed
	curve25519.ScalarBaseMult(&kp.Public, &kp.Private)
	return kp
}

// SymmetricKey is a 32-byte AEAD key. We use a named type so the
// post-handshake API can't accidentally mix initiator/responder keys.
type SymmetricKey [32]byte

// Transport is the post-handshake send/receive context. Each direction
// has its own AEAD key + nonce counter. Nonce is a u64 little-endian
// inside a 12-byte nonce (4-byte zero prefix). Wrapping past 2^64 − 1 is
// a fatal error.
type Transport struct {
	sendKey   SymmetricKey
	recvKey   SymmetricKey
	sendNonce uint64
	recvNonce uint64 // ratchet floor; replay window lives in `replay.go`
	sendAead  cipherAead
	recvAead  cipherAead

	// sealedBytes tracks plaintext bytes encrypted since the transport
	// was created. The session supervisor pairs this with createdNanos to
	// schedule a re-handshake at the same cadence the Dart and Swift
	// mirrors use.
	sealedBytes  uint64
	createdNanos int64 // time.Now().UnixNano() at construction
}

// SealedBytes returns the running count of plaintext bytes sealed since
// the transport was minted.
func (t *Transport) SealedBytes() uint64 {
	return t.sealedBytes
}

// AgeNanos returns the wall-clock age of the transport in nanoseconds.
// Caller can compare against `time.Since` thresholds without locking.
func (t *Transport) AgeNanos() int64 {
	return timeNowNanos() - t.createdNanos
}

// cipherAead is a thin wrapper around the chacha20poly1305 AEAD so the
// transport can swap in a different cipher later without touching the
// rest of the file. The interface intentionally mirrors std `cipher.AEAD`.
type cipherAead interface {
	Seal(dst, nonce, plaintext, ad []byte) []byte
	Open(dst, nonce, ciphertext, ad []byte) ([]byte, error)
	NonceSize() int
	Overhead() int
}

// HandshakeState drives a single IK handshake. Re-use across handshakes
// is not allowed — the chaining state is single-shot.
type HandshakeState struct {
	role       HandshakeRole
	s          Keypair      // local static key
	e          Keypair      // local ephemeral key
	rs         [32]byte     // remote static (known up-front on the initiator)
	hasRS      bool
	re         [32]byte     // remote ephemeral
	hasRE      bool
	h          [32]byte     // chaining hash
	ck         [32]byte     // chaining key
	k          [32]byte     // current symmetric key (zeroes mean "no key")
	hasK       bool
	n          uint64       // AEAD nonce counter for the handshake
	done       bool
}

// NewInitiator builds a handshake from the initiator side. `s` is the
// local static keypair (typically loaded from Keychain); `rs` is the
// known responder static public key (the operator pastes this from
// `dispatch-speed-server genkey`).
func NewInitiator(s Keypair, rs [32]byte) (*HandshakeState, error) {
	hs := &HandshakeState{role: RoleInitiator, s: s, rs: rs, hasRS: true}
	hs.h = initialHash()
	hs.ck = hs.h
	hs.mixHash(rs[:])
	e, err := GenerateKeypair()
	if err != nil {
		return nil, err
	}
	hs.e = e
	return hs, nil
}

// NewResponder builds a handshake from the responder (server) side.
// The responder doesn't know the initiator's static key until after
// decrypting message 1.
func NewResponder(s Keypair) (*HandshakeState, error) {
	hs := &HandshakeState{role: RoleResponder, s: s}
	hs.h = initialHash()
	hs.ck = hs.h
	hs.mixHash(s.Public[:])
	e, err := GenerateKeypair()
	if err != nil {
		return nil, err
	}
	hs.e = e
	return hs, nil
}

// SetTestEphemeral overrides the auto-generated ephemeral key. Test-only
// — never call from production code or you'll torch forward secrecy.
func (hs *HandshakeState) SetTestEphemeral(seed [32]byte) {
	hs.e = KeypairFromSeed(seed)
}

// WriteMessage1 (initiator only) produces the first handshake message.
// Wire layout: e_pub(32) || enc(s_pub)(48) || enc(payload)(len(payload)+16).
func (hs *HandshakeState) WriteMessage1(payload []byte) ([]byte, error) {
	if hs.role != RoleInitiator {
		return nil, errors.New("crypto: WriteMessage1 requires initiator")
	}
	if len(payload) > MaxHandshakePayload {
		return nil, fmt.Errorf("crypto: handshake payload too large: %d > %d",
			len(payload), MaxHandshakePayload)
	}
	out := make([]byte, 0, 32+48+len(payload)+16)
	// -- e --
	out = append(out, hs.e.Public[:]...)
	hs.mixHash(hs.e.Public[:])
	// -- es --
	dh1, err := x25519DH(hs.e.Private[:], hs.rs[:])
	if err != nil {
		return nil, err
	}
	hs.mixKey(dh1)
	// -- s --
	encS, err := hs.encryptAndHash(hs.s.Public[:])
	if err != nil {
		return nil, err
	}
	out = append(out, encS...)
	// -- ss --
	dh2, err := x25519DH(hs.s.Private[:], hs.rs[:])
	if err != nil {
		return nil, err
	}
	hs.mixKey(dh2)
	// -- payload --
	encPayload, err := hs.encryptAndHash(payload)
	if err != nil {
		return nil, err
	}
	out = append(out, encPayload...)
	return out, nil
}

// ReadMessage1 (responder only) parses the first handshake message and
// returns the decrypted application payload. After success, the
// initiator's static key is accessible via [HandshakeState.RemoteStatic].
func (hs *HandshakeState) ReadMessage1(msg []byte) ([]byte, error) {
	if hs.role != RoleResponder {
		return nil, errors.New("crypto: ReadMessage1 requires responder")
	}
	if len(msg) < 32+48 {
		return nil, fmt.Errorf("crypto: message1 too short: %d", len(msg))
	}
	// -- e --
	copy(hs.re[:], msg[:32])
	hs.hasRE = true
	hs.mixHash(hs.re[:])
	// -- es --
	dh1, err := x25519DH(hs.s.Private[:], hs.re[:])
	if err != nil {
		return nil, err
	}
	hs.mixKey(dh1)
	// -- s --
	encS := msg[32 : 32+48]
	rs, err := hs.decryptAndHash(encS)
	if err != nil {
		return nil, fmt.Errorf("crypto: decrypt initiator static: %w", err)
	}
	if len(rs) != 32 {
		return nil, fmt.Errorf("crypto: bad initiator static len: %d", len(rs))
	}
	copy(hs.rs[:], rs)
	hs.hasRS = true
	// -- ss --
	dh2, err := x25519DH(hs.s.Private[:], hs.rs[:])
	if err != nil {
		return nil, err
	}
	hs.mixKey(dh2)
	// -- payload --
	encPayload := msg[32+48:]
	plain, err := hs.decryptAndHash(encPayload)
	if err != nil {
		return nil, fmt.Errorf("crypto: decrypt initial payload: %w", err)
	}
	return plain, nil
}

// WriteMessage2 (responder only) emits the second handshake message.
// Wire layout: e_pub(32) || enc(payload)(len(payload)+16).
func (hs *HandshakeState) WriteMessage2(payload []byte) (msg []byte, t *Transport, err error) {
	if hs.role != RoleResponder {
		return nil, nil, errors.New("crypto: WriteMessage2 requires responder")
	}
	if !hs.hasRE || !hs.hasRS {
		return nil, nil, errors.New("crypto: responder missing peer keys (no ReadMessage1?)")
	}
	if len(payload) > MaxHandshakePayload {
		return nil, nil, fmt.Errorf("crypto: handshake payload too large: %d > %d",
			len(payload), MaxHandshakePayload)
	}
	out := make([]byte, 0, 32+len(payload)+16)
	// -- e --
	out = append(out, hs.e.Public[:]...)
	hs.mixHash(hs.e.Public[:])
	// -- ee --
	dh1, err := x25519DH(hs.e.Private[:], hs.re[:])
	if err != nil {
		return nil, nil, err
	}
	hs.mixKey(dh1)
	// -- se -- (responder ephemeral * initiator static)
	dh2, err := x25519DH(hs.e.Private[:], hs.rs[:])
	if err != nil {
		return nil, nil, err
	}
	hs.mixKey(dh2)
	// -- payload --
	encPayload, err := hs.encryptAndHash(payload)
	if err != nil {
		return nil, nil, err
	}
	out = append(out, encPayload...)
	t, err = hs.split()
	if err != nil {
		return nil, nil, err
	}
	hs.done = true
	return out, t, nil
}

// ReadMessage2 (initiator only) consumes the responder's reply and
// returns the decrypted payload plus the post-handshake Transport.
func (hs *HandshakeState) ReadMessage2(msg []byte) (payload []byte, t *Transport, err error) {
	if hs.role != RoleInitiator {
		return nil, nil, errors.New("crypto: ReadMessage2 requires initiator")
	}
	if len(msg) < 32 {
		return nil, nil, fmt.Errorf("crypto: message2 too short: %d", len(msg))
	}
	// -- e --
	copy(hs.re[:], msg[:32])
	hs.hasRE = true
	hs.mixHash(hs.re[:])
	// -- ee --
	dh1, err := x25519DH(hs.e.Private[:], hs.re[:])
	if err != nil {
		return nil, nil, err
	}
	hs.mixKey(dh1)
	// -- se --
	dh2, err := x25519DH(hs.s.Private[:], hs.re[:])
	if err != nil {
		return nil, nil, err
	}
	hs.mixKey(dh2)
	// -- payload --
	plain, err := hs.decryptAndHash(msg[32:])
	if err != nil {
		return nil, nil, fmt.Errorf("crypto: decrypt response payload: %w", err)
	}
	t, err = hs.split()
	if err != nil {
		return nil, nil, err
	}
	hs.done = true
	return plain, t, nil
}

// RemoteStatic returns the peer's static public key. Meaningful for the
// responder after ReadMessage1 (returns the initiator's static), or for
// the initiator at any time (returns the pre-known responder key).
func (hs *HandshakeState) RemoteStatic() [32]byte { return hs.rs }

// ----- Internal helpers -----------------------------------------------

func initialHash() [32]byte {
	// Per Noise spec §5: if len(protocol_name) ≤ 32, h is the protocol
	// name zero-padded to 32 bytes; otherwise h = SHA-256(protocol_name).
	// Our protocol name is 32 bytes exactly so we take the first branch.
	var h [32]byte
	pn := []byte(ProtocolName)
	if len(pn) <= 32 {
		copy(h[:], pn)
	} else {
		sum := sha256.Sum256(pn)
		h = sum
	}
	return h
}

func (hs *HandshakeState) mixHash(data []byte) {
	h := sha256.New()
	h.Write(hs.h[:])
	h.Write(data)
	copy(hs.h[:], h.Sum(nil))
}

func (hs *HandshakeState) mixKey(input []byte) {
	ck, k := hkdf2(hs.ck[:], input)
	hs.ck = ck
	hs.k = k
	hs.hasK = true
	hs.n = 0
}

func (hs *HandshakeState) encryptAndHash(plaintext []byte) ([]byte, error) {
	if !hs.hasK {
		// Per Noise spec: if no key, encrypt is a no-op and we hash the
		// plaintext directly. This branch is hit on the very first
		// MixHash before any DH, but our IK pattern always has a key by
		// the time we call encryptAndHash, so this is defensive.
		hs.mixHash(plaintext)
		return plaintext, nil
	}
	aead, err := chacha20poly1305.New(hs.k[:])
	if err != nil {
		return nil, err
	}
	nonce := noiseNonce(hs.n)
	ct := aead.Seal(nil, nonce[:], plaintext, hs.h[:])
	hs.n++
	hs.mixHash(ct)
	return ct, nil
}

func (hs *HandshakeState) decryptAndHash(ciphertext []byte) ([]byte, error) {
	if !hs.hasK {
		hs.mixHash(ciphertext)
		return ciphertext, nil
	}
	aead, err := chacha20poly1305.New(hs.k[:])
	if err != nil {
		return nil, err
	}
	nonce := noiseNonce(hs.n)
	plain, err := aead.Open(nil, nonce[:], ciphertext, hs.h[:])
	if err != nil {
		return nil, err
	}
	hs.n++
	hs.mixHash(ciphertext)
	return plain, nil
}

func (hs *HandshakeState) split() (*Transport, error) {
	k1, k2 := hkdf2(hs.ck[:], nil)
	t := &Transport{
		sendKey: k1, recvKey: k2,
		createdNanos: timeNowNanos(),
	}
	if hs.role == RoleResponder {
		t.sendKey, t.recvKey = k2, k1
	}
	sendAead, err := chacha20poly1305.New(t.sendKey[:])
	if err != nil {
		return nil, err
	}
	recvAead, err := chacha20poly1305.New(t.recvKey[:])
	if err != nil {
		return nil, err
	}
	t.sendAead = sendAead
	t.recvAead = recvAead
	return t, nil
}

// noiseNonce builds the 12-byte ChaCha20-Poly1305 nonce from a u64 counter.
// Layout: 4 zero bytes || little-endian u64. Matches the Noise spec §5.1.
func noiseNonce(n uint64) [12]byte {
	var out [12]byte
	binary.LittleEndian.PutUint64(out[4:], n)
	return out
}

// hkdf2 is a Noise-style HKDF that emits exactly two 32-byte outputs.
// We bypass `golang.org/x/crypto/hkdf` because Noise uses a non-standard
// chunked-info construction and the std lib helper would require careful
// info=[]byte{0x01} / info=[]byte{0x02} byte tricks anyway.
func hkdf2(chainingKey, inputKeyMaterial []byte) (out1, out2 SymmetricKey) {
	// HKDF-Extract: tempKey = HMAC(chainingKey, inputKeyMaterial)
	mac := hmac.New(sha256.New, chainingKey)
	mac.Write(inputKeyMaterial)
	tempKey := mac.Sum(nil)
	// HKDF-Expand iteration 1: out1 = HMAC(tempKey, 0x01)
	mac = hmac.New(sha256.New, tempKey)
	mac.Write([]byte{0x01})
	copy(out1[:], mac.Sum(nil))
	// HKDF-Expand iteration 2: out2 = HMAC(tempKey, out1 || 0x02)
	mac = hmac.New(sha256.New, tempKey)
	mac.Write(out1[:])
	mac.Write([]byte{0x02})
	copy(out2[:], mac.Sum(nil))
	return out1, out2
}

// x25519DH wraps `curve25519.X25519` with a stable error message and
// rejects the all-zero output (would indicate a low-order point on the
// peer side — Noise spec recommends abort).
func x25519DH(priv, pub []byte) ([]byte, error) {
	out, err := curve25519.X25519(priv, pub)
	if err != nil {
		return nil, fmt.Errorf("crypto: X25519 failed: %w", err)
	}
	var allZero [32]byte
	if subtleEqual(out, allZero[:]) {
		return nil, errors.New("crypto: X25519 output is all-zero (low-order point)")
	}
	return out, nil
}

// subtleEqual is a constant-time compare we use only for the all-zero
// check (which doesn't need to be constant-time per se, but the habit is
// worth keeping near crypto code).
func subtleEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}

// ----- Transport API ---------------------------------------------------

// Seal AEAD-encrypts plaintext with the caller's send key. The returned
// nonce is the integer counter (caller's responsibility to put on the
// wire); the returned ciphertext already includes the 16-byte tag.
// Additional data `ad` is authenticated but not encrypted.
func (t *Transport) Seal(ad, plaintext []byte) (nonce uint64, ciphertext []byte, err error) {
	if t.sendNonce == ^uint64(0) {
		return 0, nil, errors.New("crypto: send nonce exhausted (rekey required)")
	}
	n := t.sendNonce
	npad := noiseNonce(n)
	ct := t.sendAead.Seal(nil, npad[:], plaintext, ad)
	t.sendNonce++
	t.sealedBytes += uint64(len(plaintext))
	return n, ct, nil
}

// Open AEAD-decrypts a wire frame. Caller is responsible for replay-window
// gatekeeping — Open only enforces the AEAD tag.
func (t *Transport) Open(nonce uint64, ad, ciphertext []byte) ([]byte, error) {
	npad := noiseNonce(nonce)
	return t.recvAead.Open(nil, npad[:], ciphertext, ad)
}

// SendNonce returns the next nonce the Seal() call would use. Diagnostic
// only — never feed back into Seal.
func (t *Transport) SendNonce() uint64 { return t.sendNonce }

// DefaultRotateBytes is the byte threshold beyond which the transport
// should be rotated (replaced by a fresh handshake). 1 GiB matches the
// Dart / Swift mirrors and the master plan spec.
const DefaultRotateBytes uint64 = 1 << 30

// DefaultRotateAgeNanos is the wall-clock age threshold beyond which the
// transport should be rotated. 30 minutes matches the spec.
const DefaultRotateAgeNanos int64 = int64(30) * int64(60) * int64(1e9)

// NeedsRotation returns true once the transport has crossed *either* the
// byte cap or the wall-clock age cap. The caller (typically the relay's
// session supervisor) is responsible for scheduling the re-handshake.
func (t *Transport) NeedsRotation(maxBytes uint64, maxAgeNanos int64) bool {
	if maxBytes == 0 {
		maxBytes = DefaultRotateBytes
	}
	if maxAgeNanos == 0 {
		maxAgeNanos = DefaultRotateAgeNanos
	}
	if t.sealedBytes >= maxBytes {
		return true
	}
	if t.AgeNanos() >= maxAgeNanos {
		return true
	}
	return false
}

// timeNow is wrapped so tests can stub the wall clock by replacing this
// package-level var.
var timeNow = time.Now

// timeNowNanos is the nanosecond-precision twin used inside Transport for
// the rotation cadence calculations. Indirected through `timeNow` so a
// single stub controls both helpers.
var timeNowNanos = func() int64 { return timeNow().UnixNano() }
