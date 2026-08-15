// 4.3 수신 — 세션 상태 머신 (idle→pending→sending, 동시 1세션 R4)
package transfer

import (
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"easysend/internal/protocol"
	"easysend/internal/security"
)

type state int

const (
	stateIdle state = iota
	statePending
	stateSending
)

// ApprovalFunc — 승인 다이얼로그에 해당. 60초 안에 결과가 없으면 408 (4.3).
type ApprovalFunc func(req protocol.PrepareUploadRequest, isNewDevice bool) bool

type SavedFile struct {
	Path string
	From string
}

type Receiver struct {
	identity   *security.Identity
	trust      *security.TrustStore
	saveDir    string
	self       protocol.DeviceInfo
	onApproval ApprovalFunc
	onSaved    func(SavedFile)

	mu        sync.Mutex
	state     state
	sessionID string
	tokens    map[string]string // fileId → token
	files     map[string]protocol.FileMeta
	remaining map[string]bool
	fromAlias string

	Port int
}

func NewReceiver(identity *security.Identity, trust *security.TrustStore, saveDir string,
	self protocol.DeviceInfo, onApproval ApprovalFunc, onSaved func(SavedFile)) *Receiver {
	return &Receiver{identity: identity, trust: trust, saveDir: saveDir,
		self: self, onApproval: onApproval, onSaved: onSaved}
}

// Start — 53318에 HTTPS 서버를 연다. 사용 중이면 임의 포트로 폴백 (4.1)
func (r *Receiver) Start() error {
	ln, err := net.Listen("tcp4", ":"+strconv.Itoa(protocol.ServicePort))
	if err != nil {
		ln, err = net.Listen("tcp4", ":0")
		if err != nil {
			return err
		}
	}
	r.Port = ln.Addr().(*net.TCPAddr).Port

	mux := http.NewServeMux()
	mux.HandleFunc("POST "+protocol.APIPrefix+"/info", r.handleInfo)
	mux.HandleFunc("POST "+protocol.APIPrefix+"/prepare-upload", r.handlePrepare)
	mux.HandleFunc("POST "+protocol.APIPrefix+"/upload", r.handleUpload)
	mux.HandleFunc("POST "+protocol.APIPrefix+"/cancel", r.handleCancel)

	server := &http.Server{Handler: mux, TLSConfig: &tls.Config{
		Certificates: []tls.Certificate{r.identity.Certificate},
	}}
	go server.Serve(tls.NewListener(ln, server.TLSConfig))
	return nil
}

func (r *Receiver) handleInfo(w http.ResponseWriter, req *http.Request) {
	io.Copy(io.Discard, req.Body)
	json.NewEncoder(w).Encode(r.selfWithPort())
}

func (r *Receiver) selfWithPort() protocol.DeviceInfo {
	info := r.self
	info.Port = r.Port
	return info
}

func (r *Receiver) handlePrepare(w http.ResponseWriter, req *http.Request) {
	var prepare protocol.PrepareUploadRequest
	if err := json.NewDecoder(req.Body).Decode(&prepare); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	r.mu.Lock()
	if r.state != stateIdle {
		r.mu.Unlock()
		w.WriteHeader(http.StatusConflict)
		return
	}
	r.state = statePending
	r.mu.Unlock()

	approved := make(chan bool, 1)
	go func() { approved <- r.onApproval(prepare, r.trust.Contains(prepare.Info.Fingerprint) == false) }()

	select {
	case ok := <-approved:
		if ok == false {
			r.setIdle()
			w.WriteHeader(http.StatusForbidden)
			return
		}
	case <-time.After(protocol.ApprovalTimeout):
		r.setIdle()
		w.WriteHeader(http.StatusRequestTimeout)
		return
	}

	// TrustedAt은 최초 승인 시각이므로 이미 아는 기기는 덮어쓰지 않는다 (4.4)
	if r.trust.Contains(prepare.Info.Fingerprint) == false {
		r.trust.Add(prepare.Info.Fingerprint, prepare.Info.Alias)
	}

	resp := protocol.PrepareUploadResponse{SessionID: randomHex(16), Tokens: map[string]string{}}
	r.mu.Lock()
	r.state = stateSending
	r.sessionID = resp.SessionID
	r.files = prepare.Files
	r.tokens = map[string]string{}
	r.remaining = map[string]bool{}
	r.fromAlias = prepare.Info.Alias
	for fileID := range prepare.Files {
		token := randomHex(16)
		r.tokens[fileID] = token
		resp.Tokens[fileID] = token
		r.remaining[fileID] = true
	}
	r.mu.Unlock()
	json.NewEncoder(w).Encode(resp)
}

func (r *Receiver) handleUpload(w http.ResponseWriter, req *http.Request) {
	q := req.URL.Query()
	sessionID, fileID, token := q.Get("sessionId"), q.Get("fileId"), q.Get("token")

	r.mu.Lock()
	valid := r.state == stateSending && sessionID == r.sessionID && r.tokens[fileID] == token && token != ""
	meta := r.files[fileID]
	fromAlias := r.fromAlias
	r.mu.Unlock()
	if valid == false {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	path, err := r.saveBody(meta.Name, req.Body)
	if err != nil {
		// 수신 측 내부 오류(디스크 부족 등)는 세션째 중단한다 (4.3 코드 500)
		r.setIdle()
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	r.mu.Lock()
	delete(r.remaining, fileID)
	done := len(r.remaining) == 0
	if done {
		r.state = stateIdle
		r.sessionID = ""
	}
	r.mu.Unlock()

	if r.onSaved != nil {
		r.onSaved(SavedFile{Path: path, From: fromAlias})
	}
	w.WriteHeader(http.StatusOK)
}

func (r *Receiver) handleCancel(w http.ResponseWriter, req *http.Request) {
	sessionID := req.URL.Query().Get("sessionId")
	r.mu.Lock()
	if r.state == stateSending && sessionID == r.sessionID {
		r.state = stateIdle
		r.sessionID = ""
	}
	r.mu.Unlock()
	w.WriteHeader(http.StatusOK)
}

// saveBody — 같은 이름이 있으면 "name (1).ext" 식으로 번호를 붙인다 (덮어쓰기 금지, 4.3)
func (r *Receiver) saveBody(name string, body io.Reader) (string, error) {
	base := filepath.Base(name) // 경로 조작 차단
	target := filepath.Join(r.saveDir, base)
	ext := filepath.Ext(base)
	stem := base[:len(base)-len(ext)]
	for n := 1; ; n++ {
		if _, err := os.Stat(target); os.IsNotExist(err) {
			break
		}
		target = filepath.Join(r.saveDir, fmt.Sprintf("%s (%d)%s", stem, n, ext))
	}
	f, err := os.Create(target)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := io.Copy(f, body); err != nil {
		os.Remove(target)
		return "", err
	}
	return target, nil
}

func (r *Receiver) setIdle() {
	r.mu.Lock()
	r.state = stateIdle
	r.sessionID = ""
	r.mu.Unlock()
}

func randomHex(bytes int) string {
	buf := make([]byte, bytes)
	rand.Read(buf)
	return hex.EncodeToString(buf)
}
