// 4.3 송신 — prepare-upload → 파일별 순차 업로드. TLS는 4.4의 지문 검증을 강제한다.
package transfer

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"

	"easysend/internal/protocol"
	"easysend/internal/security"
)

type StatusError struct {
	Code int
}

func (e *StatusError) Error() string {
	switch e.Code {
	case http.StatusForbidden:
		return "수신자가 거절했습니다"
	case http.StatusRequestTimeout:
		return "승인 대기 시간(60초)을 초과했습니다"
	case http.StatusConflict:
		return "수신자가 다른 전송을 진행 중입니다 (busy)"
	default:
		return fmt.Sprintf("수신 측 오류 (HTTP %d)", e.Code)
	}
}

// clientFor — 상대가 제시한 인증서 지문이 광고된 fingerprint와 다르면 즉시 연결 종료 (4.4 검증 1단계).
// expected가 빈 값이면 지문을 캡처만 한다 (IP 직접 입력 /info 교환용 — 자기일치 검증은 호출부에서).
func clientFor(expected string, captured *string) *http.Client {
	return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
		InsecureSkipVerify: true, // 자체서명 전제 — 신뢰는 CA가 아니라 아래 지문 비교로 확립한다
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			fp := security.FingerprintOf(rawCerts[0])
			if captured != nil {
				*captured = fp
			}
			if expected != "" && fp != expected {
				return fmt.Errorf("인증서 지문 불일치: 광고된 기기가 아닙니다 (%s…)", fp[:16])
			}
			return nil
		},
	}}}
}

// ExchangeInfo — IP 직접 입력 폴백 (4.2). 응답 fingerprint가 TLS 인증서 지문과 일치해야 신뢰한다.
func ExchangeInfo(addr string, self protocol.DeviceInfo) (protocol.DeviceInfo, error) {
	var tlsFingerprint string
	client := clientFor("", &tlsFingerprint)
	body, _ := json.Marshal(self)
	resp, err := client.Post("https://"+addr+protocol.APIPrefix+"/info", "application/json", bytes.NewReader(body))
	if err != nil {
		return protocol.DeviceInfo{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return protocol.DeviceInfo{}, &StatusError{Code: resp.StatusCode}
	}
	var info protocol.DeviceInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return protocol.DeviceInfo{}, err
	}
	if info.Fingerprint != tlsFingerprint {
		return protocol.DeviceInfo{}, fmt.Errorf("응답 fingerprint가 TLS 인증서 지문과 다릅니다")
	}
	return info, nil
}

type Sender struct {
	addr   string
	client *http.Client
	self   protocol.DeviceInfo
}

func NewSender(addr, expectedFingerprint string, self protocol.DeviceInfo) *Sender {
	return &Sender{addr: addr, client: clientFor(expectedFingerprint, nil), self: self}
}

func (s *Sender) url(path string, query url.Values) string {
	u := url.URL{Scheme: "https", Host: s.addr, Path: protocol.APIPrefix + path, RawQuery: query.Encode()}
	return u.String()
}

func (s *Sender) PrepareUpload(files map[string]protocol.FileMeta) (protocol.PrepareUploadResponse, error) {
	body, _ := json.Marshal(protocol.PrepareUploadRequest{Info: s.self, Files: files})
	resp, err := s.client.Post(s.url("/prepare-upload", nil), "application/json", bytes.NewReader(body))
	if err != nil {
		return protocol.PrepareUploadResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return protocol.PrepareUploadResponse{}, &StatusError{Code: resp.StatusCode}
	}
	var out protocol.PrepareUploadResponse
	return out, json.NewDecoder(resp.Body).Decode(&out)
}

// UploadFile — 바디는 파일 원본 바이트 그대로 (multipart 없음, 4.3)
func (s *Sender) UploadFile(sessionID, fileID, token, path string, size int64) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	q := url.Values{"sessionId": {sessionID}, "fileId": {fileID}, "token": {token}}
	req, err := http.NewRequest(http.MethodPost, s.url("/upload", q), f)
	if err != nil {
		return err
	}
	req.ContentLength = size
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		return &StatusError{Code: resp.StatusCode}
	}
	return nil
}

func (s *Sender) Cancel(sessionID string) {
	q := url.Values{"sessionId": {sessionID}}
	resp, err := s.client.Post(s.url("/cancel", q), "application/json", nil)
	if err == nil {
		resp.Body.Close()
	}
}
