package auth

import (
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func tmpDir(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("", "dispatch-auth-")
	if err != nil {
		t.Fatalf("mkdtemp: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(d) })
	return d
}

func TestGenerateKey_RoundTrips(t *testing.T) {
	dir := tmpDir(t)
	path := filepath.Join(dir, "server.key")

	priv, err := GenerateKey(path, false)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	if len(priv) != ed25519.PrivateKeySize {
		t.Fatalf("priv len=%d want %d", len(priv), ed25519.PrivateKeySize)
	}

	loaded, err := LoadKey(path)
	if err != nil {
		t.Fatalf("LoadKey: %v", err)
	}
	if string(loaded) != string(priv) {
		t.Fatalf("LoadKey returned different bytes")
	}

	// Mode bits should be 0600 — leaking the key would defeat the point.
	st, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := st.Mode().Perm(); perm != 0o600 {
		t.Fatalf("key perm = %v, want 0600", perm)
	}
}

func TestGenerateKey_RefusesOverwriteByDefault(t *testing.T) {
	dir := tmpDir(t)
	path := filepath.Join(dir, "server.key")
	if _, err := GenerateKey(path, false); err != nil {
		t.Fatalf("first generate: %v", err)
	}
	if _, err := GenerateKey(path, false); err == nil {
		t.Fatalf("expected ErrKeyExists on second call")
	}
	// Force=true must succeed.
	if _, err := GenerateKey(path, true); err != nil {
		t.Fatalf("force overwrite: %v", err)
	}
}

func TestPublicKeyBase64_Stable(t *testing.T) {
	dir := tmpDir(t)
	path := filepath.Join(dir, "server.key")
	priv, err := GenerateKey(path, false)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	got := PublicKeyBase64(priv)
	// Should decode to 32 bytes (Ed25519 pubkey).
	raw, err := base64.StdEncoding.DecodeString(got)
	if err != nil {
		t.Fatalf("decode pub: %v", err)
	}
	if len(raw) != ed25519.PublicKeySize {
		t.Fatalf("pub len=%d want %d", len(raw), ed25519.PublicKeySize)
	}
}

func TestManager_AddUserAndVerify(t *testing.T) {
	dir := tmpDir(t)
	path := filepath.Join(dir, "auth.json")

	m, err := OpenManager(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	user, err := m.AddUser("alice")
	if err != nil {
		t.Fatalf("AddUser: %v", err)
	}
	if user.Token == "" {
		t.Fatalf("expected non-empty token")
	}
	if !m.Verify("alice", user.Token) {
		t.Fatalf("Verify should accept the freshly-minted token")
	}
	if m.Verify("alice", user.Token+"x") {
		t.Fatalf("Verify must reject a wrong token")
	}
	if m.Verify("bob", user.Token) {
		t.Fatalf("Verify must reject a wrong username")
	}
}

func TestManager_PersistsAcrossReopen(t *testing.T) {
	dir := tmpDir(t)
	path := filepath.Join(dir, "auth.json")

	m1, _ := OpenManager(path)
	a, _ := m1.AddUser("alice")
	b, _ := m1.AddUser("bob")

	m2, err := OpenManager(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if !m2.Verify("alice", a.Token) {
		t.Fatalf("alice token did not survive reopen")
	}
	if !m2.Verify("bob", b.Token) {
		t.Fatalf("bob token did not survive reopen")
	}
}

func TestManager_RejectsDuplicateUser(t *testing.T) {
	dir := tmpDir(t)
	path := filepath.Join(dir, "auth.json")
	m, _ := OpenManager(path)
	if _, err := m.AddUser("alice"); err != nil {
		t.Fatalf("first add: %v", err)
	}
	if _, err := m.AddUser("alice"); err == nil {
		t.Fatalf("expected error on duplicate user")
	}
}

func TestManager_RejectsEmptyName(t *testing.T) {
	dir := tmpDir(t)
	path := filepath.Join(dir, "auth.json")
	m, _ := OpenManager(path)
	if _, err := m.AddUser(""); err == nil {
		t.Fatalf("expected error on empty user")
	}
}

func TestManager_RejectsFutureSchema(t *testing.T) {
	dir := tmpDir(t)
	path := filepath.Join(dir, "auth.json")
	// Hand-write a v999 file.
	if err := os.WriteFile(path,
		[]byte(`{"version":999,"users":[]}`), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := OpenManager(path); err == nil {
		t.Fatalf("expected version-mismatch rejection")
	}
}
