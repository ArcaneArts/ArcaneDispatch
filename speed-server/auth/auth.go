// Package auth handles the speed server's on-disk credentials.
//
// Two artifacts live here:
//
//   * **Server key** — an Ed25519 keypair on disk. Phase 9 will use this
//     identity inside the Noise IK handshake. For Phase 8 it just exists
//     so the deployment shape is final and operators don't have to redo
//     their bootstrap when crypto lands.
//   * **Auth store** — a JSON-on-disk map of `username → token`. Tokens
//     are 256 bits of crypto/rand b64-encoded. Phase 9 swaps this for
//     static-key pinning; the file format includes a `version` field so
//     a forward-compat migration is mechanical.
//
// Concurrency: every mutation reads, mutates, then writes the entire
// file atomically (write to `*.tmp`, fsync, rename). This is fine for
// the < 10k-user volumes the OSS deploy targets. Multi-writer setups
// would need a real DB; that's out of scope.
package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// ----- Server identity ----------------------------------------------------

// ErrKeyExists is returned by GenerateKey when refusing to overwrite.
var ErrKeyExists = errors.New("auth: key file already exists")

// GenerateKey writes a fresh Ed25519 private key to `path` in raw 64-byte
// format (Go's `ed25519.PrivateKey` is a 64-byte slice: 32-byte seed +
// 32-byte public key). Setting `force` to false makes the call idempotent
// — refusing to clobber an existing file is the safer default for a tool
// that ships in operator boxes.
func GenerateKey(path string, force bool) (ed25519.PrivateKey, error) {
	if !force {
		if _, err := os.Stat(path); err == nil {
			return nil, fmt.Errorf("%w: %s", ErrKeyExists, path)
		}
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate ed25519 key: %w", err)
	}
	if err := writeFileAtomic(path, priv, 0o600); err != nil {
		return nil, err
	}
	return priv, nil
}

// LoadKey reads an Ed25519 private key from disk. Validates length so a
// corrupt file is rejected loudly instead of silently mis-signing.
func LoadKey(path string) (ed25519.PrivateKey, error) {
	bytes, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read key %s: %w", path, err)
	}
	if len(bytes) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("auth: key %s is %d bytes, want %d",
			path, len(bytes), ed25519.PrivateKeySize)
	}
	return ed25519.PrivateKey(bytes), nil
}

// PublicKeyBase64 derives and base64-encodes the public half of priv.
// Useful for the CLI to print a copy-pasteable server identity.
func PublicKeyBase64(priv ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
}

// ----- Auth store ---------------------------------------------------------

// User is a single entry in the auth store. The token is the bearer
// shared secret the client mints with `adduser`; the server-side check
// is a constant-time string compare in the handshake (Phase 9).
type User struct {
	Name  string `json:"name"`
	Token string `json:"token"`
}

// Store is the on-disk auth file. The wire format is JSON for human-
// edit-ability — operators routinely have to nuke a leaked token by
// hand, and JSON is grep-friendly.
type Store struct {
	Version int    `json:"version"`
	Users   []User `json:"users"`
}

// storeFile is the on-disk JSON layout. Kept distinct from Store so we
// can evolve the public type without a wire-format break.
type storeFile struct {
	Version int    `json:"version"`
	Users   []User `json:"users"`
}

const storeFormatVersion = 1

// Manager wraps a Store with on-disk persistence and a mutex so the CLI
// can update from multiple goroutines without races. The relay reads
// through the Manager too once auth wiring lands in Phase 9.
type Manager struct {
	mu   sync.Mutex
	path string
	data Store
}

// OpenManager loads (or creates) the auth store at `path`. A missing
// file is treated as an empty store — the file is materialised on the
// first mutating call (AddUser / Save) so a freshly-installed operator
// can run `genkey` without `adduser` and still have a coherent state.
func OpenManager(path string) (*Manager, error) {
	m := &Manager{path: path}
	bytes, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			m.data = Store{Version: storeFormatVersion}
			return m, nil
		}
		return nil, fmt.Errorf("read auth store %s: %w", path, err)
	}
	var sf storeFile
	if err := json.Unmarshal(bytes, &sf); err != nil {
		return nil, fmt.Errorf("parse auth store %s: %w", path, err)
	}
	if sf.Version == 0 {
		sf.Version = storeFormatVersion
	}
	if sf.Version > storeFormatVersion {
		return nil, fmt.Errorf("auth store version %d is newer than %d",
			sf.Version, storeFormatVersion)
	}
	m.data = Store{Version: sf.Version, Users: sf.Users}
	return m, nil
}

// Path returns the on-disk path the manager was opened from.
func (m *Manager) Path() string { return m.path }

// AddUser appends a new user with a freshly-minted token, persists the
// store, and returns the token so the operator can copy it once. The
// token is never read back from disk — if a user loses it they have to
// rotate.
func (m *Manager) AddUser(name string) (User, error) {
	if name == "" {
		return User{}, errors.New("auth: user name is required")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, u := range m.data.Users {
		if u.Name == name {
			return User{}, fmt.Errorf("auth: user %q already exists", name)
		}
	}
	tok, err := mintToken()
	if err != nil {
		return User{}, err
	}
	user := User{Name: name, Token: tok}
	m.data.Users = append(m.data.Users, user)
	sort.Slice(m.data.Users, func(i, j int) bool {
		return m.data.Users[i].Name < m.data.Users[j].Name
	})
	if m.data.Version == 0 {
		m.data.Version = storeFormatVersion
	}
	if err := m.save(); err != nil {
		return User{}, err
	}
	return user, nil
}

// Verify reports whether the supplied (name, token) pair matches a
// stored user. Constant-time compare is enforced by Phase 9 when the
// handshake actually runs auth — this method is only used by tests and
// the upcoming relay glue.
func (m *Manager) Verify(name, token string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, u := range m.data.Users {
		if u.Name == name && u.Token == token {
			return true
		}
	}
	return false
}

// Users returns a copy of the user list (without leaking the underlying
// slice). Used by the `stats` CLI to summarise active operators.
func (m *Manager) Users() []User {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]User, len(m.data.Users))
	copy(out, m.data.Users)
	return out
}

// save writes the in-memory store to disk atomically. Always called with
// `m.mu` held.
func (m *Manager) save() error {
	sf := storeFile{Version: m.data.Version, Users: m.data.Users}
	bytes, err := json.MarshalIndent(sf, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal auth store: %w", err)
	}
	bytes = append(bytes, '\n')
	return writeFileAtomic(m.path, bytes, 0o600)
}

// mintToken produces 32 bytes of crypto/rand encoded as URL-safe b64
// without padding — short enough to paste into env vars but plenty of
// entropy (256 bits).
func mintToken() (string, error) {
	var raw [32]byte
	if _, err := io.ReadFull(rand.Reader, raw[:]); err != nil {
		return "", fmt.Errorf("mint token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw[:]), nil
}

// writeFileAtomic is a tmp+rename writer so a partial write never leaves
// the store in a corrupt state. We MkdirAll the parent so first-run on
// an empty deploy works without the operator pre-creating dirs.
func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp %s: %w", path, err)
	}
	tmpPath := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpPath) }
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("write %s: %w", tmpPath, err)
	}
	if err := tmp.Chmod(perm); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("chmod %s: %w", tmpPath, err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("sync %s: %w", tmpPath, err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return fmt.Errorf("close %s: %w", tmpPath, err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		cleanup()
		return fmt.Errorf("rename %s -> %s: %w", tmpPath, path, err)
	}
	return nil
}
