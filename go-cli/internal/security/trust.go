// 4.4 TOFU 신뢰 목록 — (지문, alias, 최초 승인 시각)을 로컬 JSON에 저장
package security

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type TrustedDevice struct {
	Alias     string    `json:"alias"`
	TrustedAt time.Time `json:"trustedAt"`
}

type TrustStore struct {
	path    string
	devices map[string]TrustedDevice
}

func OpenTrustStore(dir string) (*TrustStore, error) {
	store := &TrustStore{
		path:    filepath.Join(dir, "trusted.json"),
		devices: map[string]TrustedDevice{},
	}
	data, err := os.ReadFile(store.path)
	if os.IsNotExist(err) {
		return store, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &store.devices); err != nil {
		return nil, err
	}
	return store, nil
}

func (s *TrustStore) Contains(fingerprint string) bool {
	_, ok := s.devices[fingerprint]
	return ok
}

func (s *TrustStore) Add(fingerprint, alias string) error {
	s.devices[fingerprint] = TrustedDevice{Alias: alias, TrustedAt: time.Now()}
	data, err := json.MarshalIndent(s.devices, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(s.path, data, 0o600)
}
