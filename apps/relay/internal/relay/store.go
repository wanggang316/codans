package relay

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
)

const storeFileName = "relay.json"

// maxMacs caps registrations, which cost nothing to create (trust on first
// use), so the store cannot be grown without bound.
const maxMacs = 10000

// ErrStoreFull is returned when registering a new Mac past maxMacs.
var ErrStoreFull = errors.New("relay store full")

// hashCredential returns base64url-no-padding(SHA-256(s)). Mac secrets and
// phone tokens are both stored and compared only in this form.
func hashCredential(s string) string {
	sum := sha256.Sum256([]byte(s))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func constantTimeEqual(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

type macRecord struct {
	SecretHash  string   `json:"secretHash"`
	TokenHashes []string `json:"tokenHashes"`
}

type storeFile struct {
	Version int                   `json:"version"`
	Macs    map[string]*macRecord `json:"macs"`
}

// Store holds Mac registrations and their allowed phone-token hashes, and
// persists them to a JSON file so a restart does not lock Macs out.
type Store struct {
	path string

	mu   sync.Mutex
	macs map[string]*macRecord
}

// OpenStore loads (or creates) the store in dir.
func OpenStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	s := &Store{path: filepath.Join(dir, storeFileName), macs: map[string]*macRecord{}}
	data, err := os.ReadFile(s.path)
	if errors.Is(err, fs.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read store: %w", err)
	}
	var f storeFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("decode store: %w", err)
	}
	for id, rec := range f.Macs {
		if rec != nil && validID(id) {
			s.macs[id] = rec
		}
	}
	return s, nil
}

// AuthenticateMac checks secret against the stored hash for macID. When the
// Mac is unknown and register is true, the secret is registered (trust on
// first use).
func (s *Store) AuthenticateMac(macID, secret string, register bool) (bool, error) {
	hash := hashCredential(secret)
	s.mu.Lock()
	defer s.mu.Unlock()
	if rec, ok := s.macs[macID]; ok {
		return constantTimeEqual(rec.SecretHash, hash), nil
	}
	if !register {
		return false, nil
	}
	if len(s.macs) >= maxMacs {
		return false, ErrStoreFull
	}
	s.macs[macID] = &macRecord{SecretHash: hash, TokenHashes: []string{}}
	if err := s.saveLocked(); err != nil {
		delete(s.macs, macID)
		return false, err
	}
	return true, nil
}

// SetTokenHashes replaces the Mac's allowed phone-token hashes. The in-memory
// list changes even if persisting fails, so a revocation always takes effect.
func (s *Store) SetTokenHashes(macID string, hashes []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.macs[macID]
	if !ok {
		return fmt.Errorf("mac not registered")
	}
	rec.TokenHashes = append([]string{}, hashes...)
	return s.saveLocked()
}

// Registered reports whether macID has a registration.
func (s *Store) Registered(macID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.macs[macID]
	return ok
}

// TokenAllowed reports whether token's hash is in the Mac's current list.
func (s *Store) TokenAllowed(macID, token string) bool {
	hash := hashCredential(token)
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.macs[macID]
	if !ok {
		return false
	}
	allowed := false
	for _, h := range rec.TokenHashes {
		// No early exit: the scan time does not reveal the match position.
		if constantTimeEqual(h, hash) {
			allowed = true
		}
	}
	return allowed
}

// saveLocked writes the store atomically: temp file, fsync, rename.
func (s *Store) saveLocked() error {
	data, err := json.MarshalIndent(storeFile{Version: 1, Macs: s.macs}, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), storeFileName+".*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // no-op after a successful rename
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.path)
}
