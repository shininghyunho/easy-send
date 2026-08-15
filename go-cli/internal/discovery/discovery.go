// 4.2 탐색 — 5초 멀티캐스트+서브넷 브로드캐스트 병행 announce, 유니캐스트 응답, 15초 TTL
package discovery

import (
	"context"
	"encoding/json"
	"net"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/ipv4"
	"golang.org/x/sys/unix"

	"easysend/internal/protocol"
)

type Device struct {
	protocol.DeviceInfo
	IP       net.IP
	LastSeen time.Time
}

// Addr = HTTPS 서버 주소 (announce의 port 필드 기준)
func (d Device) Addr() string {
	return net.JoinHostPort(d.IP.String(), itoa(d.Port))
}

type Discoverer struct {
	self  protocol.DeviceInfo
	conn  net.PacketConn
	pconn *ipv4.PacketConn

	mu      sync.Mutex
	devices map[string]Device
}

func New(self protocol.DeviceInfo) *Discoverer {
	return &Discoverer{self: self, devices: map[string]Device{}}
}

// Start — 53318 바인드(같은 호스트의 Flutter 앱과 공존을 위해 SO_REUSEPORT) 후
// 수신 루프와 5초 announce 루프를 돌린다. ctx 취소로 종료.
func (d *Discoverer) Start(ctx context.Context) error {
	lc := net.ListenConfig{Control: func(network, address string, c syscall.RawConn) error {
		var soErr error
		err := c.Control(func(fd uintptr) {
			for _, opt := range []int{unix.SO_REUSEADDR, unix.SO_REUSEPORT, unix.SO_BROADCAST} {
				if err := unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, opt, 1); err != nil {
					soErr = err
					return
				}
			}
		})
		if err != nil {
			return err
		}
		return soErr
	}}
	conn, err := lc.ListenPacket(ctx, "udp4", ":"+itoa(protocol.DiscoveryPort))
	if err != nil {
		return err
	}
	d.conn = conn
	d.pconn = ipv4.NewPacketConn(conn)

	group := &net.UDPAddr{IP: net.ParseIP(protocol.MulticastGroup)}
	for _, iface := range multicastInterfaces() {
		// 멀티캐스트 미지원 인터페이스(P2P VPN 등)는 건너뛴다
		_ = d.pconn.JoinGroup(&iface, group)
	}

	go d.readLoop()
	go func() {
		ticker := time.NewTicker(protocol.AnnounceInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				conn.Close()
				return
			case <-ticker.C:
				d.Announce()
			}
		}
	}()
	d.Announce()
	return nil
}

// Announce — 인터페이스를 순회하며 멀티캐스트+브로드캐스트로 이중 송신 (PRD 4.2 M4 개정)
func (d *Discoverer) Announce() {
	data, _ := json.Marshal(protocol.Announcement{DeviceInfo: d.self, Announce: true})
	groupAddr := &net.UDPAddr{IP: net.ParseIP(protocol.MulticastGroup), Port: protocol.DiscoveryPort}
	for _, iface := range multicastInterfaces() {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if ok == false || ipnet.IP.To4() == nil {
				continue
			}
			// 송신 불가 인터페이스는 건너뛴다
			_ = d.pconn.SetMulticastInterface(&iface)
			_, _ = d.conn.WriteTo(data, groupAddr)
			_, _ = d.conn.WriteTo(data, &net.UDPAddr{IP: broadcastOf(ipnet), Port: protocol.DiscoveryPort})
		}
	}
}

func (d *Discoverer) readLoop() {
	buf := make([]byte, 4096)
	for {
		n, src, err := d.conn.ReadFrom(buf)
		if err != nil {
			return
		}
		ann, err := protocol.DecodeAnnouncement(buf[:n])
		if err != nil {
			continue
		}
		// 내가 보낸 것이 되돌아온 경우 (4.2 규칙 3)
		if ann.Fingerprint == d.self.Fingerprint {
			continue
		}
		udpSrc, ok := src.(*net.UDPAddr)
		if ok == false {
			continue
		}
		d.mu.Lock()
		d.devices[ann.Fingerprint] = Device{DeviceInfo: ann.DeviceInfo, IP: udpSrc.IP, LastSeen: time.Now()}
		d.mu.Unlock()
		if ann.Announce {
			reply, _ := json.Marshal(protocol.Announcement{DeviceInfo: d.self, Announce: false})
			_, _ = d.conn.WriteTo(reply, udpSrc)
		}
	}
}

// Devices — TTL(15초) 지난 항목을 제거한 스냅샷을 alias 순으로 반환
func (d *Discoverer) Devices() []Device {
	d.mu.Lock()
	defer d.mu.Unlock()
	var list []Device
	for fp, dev := range d.devices {
		if time.Since(dev.LastSeen) > protocol.DeviceTTL {
			delete(d.devices, fp)
			continue
		}
		list = append(list, dev)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Alias < list[j].Alias })
	return list
}

func multicastInterfaces() []net.Interface {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var result []net.Interface
	for _, iface := range ifaces {
		up := iface.Flags&net.FlagUp != 0
		multicast := iface.Flags&net.FlagMulticast != 0
		loopback := iface.Flags&net.FlagLoopback != 0
		if up && multicast && loopback == false {
			result = append(result, iface)
		}
	}
	return result
}

// broadcastOf — 실제 넷마스크 기반 브로드캐스트 주소 (dart:io와 달리 /24 가정 불필요)
func broadcastOf(ipnet *net.IPNet) net.IP {
	ip := ipnet.IP.To4()
	mask := ipnet.Mask
	if len(mask) == net.IPv6len {
		mask = mask[12:]
	}
	bcast := make(net.IP, 4)
	for i := 0; i < 4; i++ {
		bcast[i] = ip[i] | ^mask[i]
	}
	return bcast
}

func itoa(n int) string { return strconv.Itoa(n) }
