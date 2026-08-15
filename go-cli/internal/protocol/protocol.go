// PRD 4장 프로토콜 스펙 v1의 공통 상수·스키마 (Dart core와 와이어 호환이 계약)
package protocol

import (
	"encoding/json"
	"fmt"
	"time"
)

const (
	App              = "easy-send"
	Version          = "1.0"
	MulticastGroup   = "224.0.0.168"
	DiscoveryPort    = 53318
	ServicePort      = 53318
	APIPrefix        = "/api/v1"
	AnnounceInterval = 5 * time.Second
	DeviceTTL        = 15 * time.Second
	ApprovalTimeout  = 60 * time.Second
)

// DeviceInfo = announce 스키마에서 announce 플래그를 뺀 기기 정보 (4.2)
type DeviceInfo struct {
	App         string `json:"app"`
	Version     string `json:"version"`
	Alias       string `json:"alias"`
	DeviceType  string `json:"deviceType"`
	Fingerprint string `json:"fingerprint"`
	Port        int    `json:"port"`
	Protocol    string `json:"protocol"`
}

type Announcement struct {
	DeviceInfo
	Announce bool `json:"announce"`
}

// 다른 앱이거나 메이저 버전이 다르면 무시한다 (4.2 필드 규칙)
func (d DeviceInfo) Compatible() bool {
	return d.App == App && majorOf(d.Version) == majorOf(Version)
}

func majorOf(v string) string {
	for i := 0; i < len(v); i++ {
		if v[i] == '.' {
			return v[:i]
		}
	}
	return v
}

func DecodeAnnouncement(data []byte) (Announcement, error) {
	var a Announcement
	if err := json.Unmarshal(data, &a); err != nil {
		return a, err
	}
	if a.Compatible() == false {
		return a, fmt.Errorf("호환되지 않는 피어: app=%q version=%q", a.App, a.Version)
	}
	return a, nil
}

// FileMeta = prepare-upload files 항목 (4.3)
type FileMeta struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	Mime string `json:"mime"`
}

type PrepareUploadRequest struct {
	Info  DeviceInfo          `json:"info"`
	Files map[string]FileMeta `json:"files"`
}

type PrepareUploadResponse struct {
	SessionID string            `json:"sessionId"`
	Tokens    map[string]string `json:"tokens"`
}
