// easy-send Go CLI 피어 — PRD 4장 스펙 구현 (Phase 2)
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"mime"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"easysend/internal/discovery"
	"easysend/internal/protocol"
	"easysend/internal/security"
	"easysend/internal/transfer"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "ls":
		err = cmdLs(os.Args[2:])
	case "send":
		err = cmdSend(os.Args[2:])
	case "recv":
		err = cmdRecv(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "오류:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `사용법:
  easy-send ls                          발견된 기기 목록 (3초 탐색)
  easy-send send <파일...> --to <대상>   파일 전송 (대상 = alias 또는 IP[:포트])
  easy-send recv [--dir 폴더]            수신 대기 (기본 저장 위치: 현재 폴더)`)
}

func configDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".easy-send"
	}
	return filepath.Join(home, ".easy-send")
}

// selfInfo — 이 프로세스의 announce용 기기 정보. port는 recv에서만 실제 서버 포트로 교체된다.
func selfInfo(alias string, identity *security.Identity, port int) protocol.DeviceInfo {
	if alias == "" {
		host, err := os.Hostname()
		if err == nil {
			alias = strings.TrimSuffix(host, ".local")
		} else {
			alias = "easy-send-cli"
		}
	}
	return protocol.DeviceInfo{
		App: protocol.App, Version: protocol.Version,
		Alias: alias, DeviceType: "desktop",
		Fingerprint: identity.Fingerprint, Port: port, Protocol: "https",
	}
}

func cmdLs(args []string) error {
	fs := flag.NewFlagSet("ls", flag.ExitOnError)
	alias := fs.String("alias", "", "내 기기 이름 (기본: 호스트명)")
	wait := fs.Duration("wait", 3*time.Second, "탐색 대기 시간")
	fs.Parse(args)

	identity, err := security.LoadOrCreate(configDir())
	if err != nil {
		return err
	}
	d := discovery.New(selfInfo(*alias, identity, protocol.ServicePort))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := d.Start(ctx); err != nil {
		return err
	}
	fmt.Printf("발견된 기기 (%s 탐색):\n", wait)
	time.Sleep(*wait)
	devices := d.Devices()
	if len(devices) == 0 {
		fmt.Println("  (없음)")
		return nil
	}
	for i, dev := range devices {
		fmt.Printf("  %d. %-24s %-8s %s\n", i+1, dev.Alias, dev.DeviceType, dev.Addr())
	}
	return nil
}

func cmdSend(args []string) error {
	fs := flag.NewFlagSet("send", flag.ExitOnError)
	to := fs.String("to", "", "대상 alias 또는 IP[:포트] (필수)")
	alias := fs.String("alias", "", "내 기기 이름 (기본: 호스트명)")
	// Go flag는 위치 인자 뒤의 플래그를 안 읽으므로 플래그를 앞으로 재배열한다
	var flagArgs, positional []string
	for i := 0; i < len(args); i++ {
		if strings.HasPrefix(args[i], "-") {
			flagArgs = append(flagArgs, args[i])
			if strings.Contains(args[i], "=") == false && i+1 < len(args) {
				i++
				flagArgs = append(flagArgs, args[i])
			}
		} else {
			positional = append(positional, args[i])
		}
	}
	fs.Parse(append(flagArgs, positional...))
	paths := fs.Args()
	if *to == "" || len(paths) == 0 {
		return fmt.Errorf("사용법: easy-send send <파일...> --to <대상>")
	}
	for _, p := range paths {
		if info, err := os.Stat(p); err != nil || info.IsDir() {
			return fmt.Errorf("파일이 아니거나 읽을 수 없습니다: %s", p)
		}
	}

	dir := configDir()
	identity, err := security.LoadOrCreate(dir)
	if err != nil {
		return err
	}
	trust, err := security.OpenTrustStore(dir)
	if err != nil {
		return err
	}
	self := selfInfo(*alias, identity, protocol.ServicePort)

	target, err := resolveTarget(*to, self)
	if err != nil {
		return err
	}

	// 송신 측 TOFU — 처음 보내는 기기면 1회 신뢰 확인 (4.4)
	if trust.Contains(target.Fingerprint) == false {
		ok := promptYN(fmt.Sprintf("새 기기입니다. 신뢰할까요? (%s, 지문 %s…) [y/N] ",
			target.Alias, target.Fingerprint[:16]))
		if ok == false {
			return fmt.Errorf("사용자가 신뢰를 거부했습니다")
		}
		if err := trust.Add(target.Fingerprint, target.Alias); err != nil {
			return err
		}
	}

	files := map[string]protocol.FileMeta{}
	for i, p := range paths {
		mimeType := mime.TypeByExtension(filepath.Ext(p))
		if mimeType == "" {
			mimeType = "application/octet-stream"
		}
		info, _ := os.Stat(p)
		files[fmt.Sprintf("f%d", i+1)] = protocol.FileMeta{
			Name: filepath.Base(p), Size: info.Size(), Mime: mimeType,
		}
	}

	sender := transfer.NewSender(target.Addr(), target.Fingerprint, self)
	fmt.Printf("%s에게 전송 요청 — 수신자 승인 대기 중 (최대 60초)…\n", target.Alias)
	session, err := sender.PrepareUpload(files)
	if err != nil {
		return err
	}

	// Ctrl+C 시 세션을 수신자에게 정리시킨다 (4.3 cancel)
	interrupted := make(chan os.Signal, 1)
	signal.Notify(interrupted, os.Interrupt)
	go func() {
		<-interrupted
		sender.Cancel(session.SessionID)
		fmt.Fprintln(os.Stderr, "\n취소됨")
		os.Exit(1)
	}()

	for i, p := range paths {
		fileID := fmt.Sprintf("f%d", i+1)
		meta := files[fileID]
		started := time.Now()
		if err := sender.UploadFile(session.SessionID, fileID, session.Tokens[fileID], p, meta.Size); err != nil {
			sender.Cancel(session.SessionID)
			return fmt.Errorf("%s 업로드 실패: %w", meta.Name, err)
		}
		elapsed := time.Since(started).Seconds()
		fmt.Printf("업로드 완료: %s (%s, %s/s)\n", meta.Name, formatSize(meta.Size),
			formatSize(int64(float64(meta.Size)/maxF(elapsed, 0.001))))
	}
	return nil
}

// resolveTarget — IP[:포트]면 /info 교환(폴백), 아니면 alias로 멀티캐스트 탐색
func resolveTarget(to string, self protocol.DeviceInfo) (discovery.Device, error) {
	host, port := to, protocol.ServicePort
	if h, p, err := net.SplitHostPort(to); err == nil {
		host = h
		fmt.Sscanf(p, "%d", &port)
	}
	if ip := net.ParseIP(host); ip != nil {
		addr := net.JoinHostPort(host, fmt.Sprintf("%d", port))
		info, err := transfer.ExchangeInfo(addr, self)
		if err != nil {
			return discovery.Device{}, fmt.Errorf("IP 직접 연결 실패 (%s): %w", addr, err)
		}
		return discovery.Device{DeviceInfo: info, IP: ip, LastSeen: time.Now()}, nil
	}

	d := discovery.New(self)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := d.Start(ctx); err != nil {
		return discovery.Device{}, err
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		for _, dev := range d.Devices() {
			if dev.Alias == to {
				return dev, nil
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return discovery.Device{}, fmt.Errorf("기기를 찾지 못했습니다: %s (10초 탐색)", to)
}

func cmdRecv(args []string) error {
	fs := flag.NewFlagSet("recv", flag.ExitOnError)
	saveDir := fs.String("dir", ".", "저장 폴더")
	alias := fs.String("alias", "", "내 기기 이름 (기본: 호스트명)")
	fs.Parse(args)

	dir := configDir()
	identity, err := security.LoadOrCreate(dir)
	if err != nil {
		return err
	}
	trust, err := security.OpenTrustStore(dir)
	if err != nil {
		return err
	}

	self := selfInfo(*alias, identity, 0)
	receiver := transfer.NewReceiver(identity, trust, *saveDir, self,
		func(req protocol.PrepareUploadRequest, isNewDevice bool) bool {
			var names []string
			var total int64
			for _, f := range req.Files {
				names = append(names, f.Name)
				total += f.Size
			}
			badge := ""
			if isNewDevice {
				badge = " [새 기기]"
			}
			return promptYN(fmt.Sprintf("← %s%s가 %s (%s) 전송 요청 [y/N] ",
				req.Info.Alias, badge, strings.Join(names, ", "), formatSize(total)))
		},
		func(saved transfer.SavedFile) {
			fmt.Printf("저장 완료: %s (보낸 기기: %s)\n", saved.Path, saved.From)
		})
	if err := receiver.Start(); err != nil {
		return err
	}

	self.Port = receiver.Port
	d := discovery.New(self)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := d.Start(ctx); err != nil {
		return err
	}

	fmt.Printf("수신 대기 중 (alias: %s, 포트: %d, 저장: %s) — Ctrl+C로 종료\n",
		self.Alias, receiver.Port, *saveDir)
	interrupted := make(chan os.Signal, 1)
	signal.Notify(interrupted, os.Interrupt)
	<-interrupted
	return nil
}

var stdin = bufio.NewScanner(os.Stdin)

func promptYN(message string) bool {
	fmt.Print(message)
	if stdin.Scan() == false {
		return false
	}
	answer := strings.ToLower(strings.TrimSpace(stdin.Text()))
	return answer == "y" || answer == "yes"
}

func formatSize(bytes int64) string {
	const mb = 1024 * 1024
	if bytes >= mb {
		return fmt.Sprintf("%.1f MB", float64(bytes)/mb)
	}
	return fmt.Sprintf("%.1f KB", float64(bytes)/1024)
}

func maxF(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
