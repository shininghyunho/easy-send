// 4.2 탐색 — 5초 멀티캐스트+서브넷 브로드캐스트 병행 announce, 유니캐스트 응답, 15초 TTL
use crate::core::protocol::{
    Announcement, PeerInfo, ANNOUNCE_INTERVAL, DEVICE_TTL, DISCOVERY_PORT, MULTICAST_GROUP,
};
use anyhow::Result;
use socket2::{Domain, Protocol, SockRef, Socket, Type};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::net::UdpSocket;

#[derive(Clone)]
pub struct Device {
    pub info: PeerInfo,
    pub ip: IpAddr,
    pub last_seen: Instant,
}

impl Device {
    // HTTPS 서버 주소 (announce의 port 필드 기준)
    pub fn addr(&self) -> String {
        format!("{}:{}", self.ip, self.info.port)
    }
}

pub struct Discoverer {
    self_info: PeerInfo,
    socket: Arc<UdpSocket>,
    devices: Arc<Mutex<HashMap<String, Device>>>,
}

impl Discoverer {
    // 53318 바인드(같은 호스트의 다른 피어와 공존을 위해 SO_REUSEPORT) 후
    // 수신 루프와 5초 announce 루프를 돌린다.
    pub async fn start(self_info: PeerInfo) -> Result<Discoverer> {
        let raw = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
        raw.set_reuse_address(true)?;
        #[cfg(unix)]
        raw.set_reuse_port(true)?;
        raw.set_broadcast(true)?;
        raw.set_nonblocking(true)?;
        raw.bind(&SocketAddr::from((Ipv4Addr::UNSPECIFIED, DISCOVERY_PORT)).into())?;
        let socket = Arc::new(UdpSocket::from_std(raw.into())?);

        for (ip, _) in ipv4_interfaces() {
            // 멀티캐스트 미지원 인터페이스(P2P VPN 등)는 건너뛴다
            let _ = socket.join_multicast_v4(MULTICAST_GROUP, ip);
        }

        let d = Discoverer {
            self_info,
            socket,
            devices: Arc::new(Mutex::new(HashMap::new())),
        };
        d.spawn_read_loop();
        d.spawn_announce_loop();
        d.announce().await;
        Ok(d)
    }

    // 인터페이스를 순회하며 멀티캐스트+브로드캐스트로 이중 송신 (PRD 4.2 M4 개정)
    pub async fn announce(&self) {
        let data =
            serde_json::to_vec(&Announcement::new(self.self_info.clone(), true)).unwrap_or_default();
        for (ip, broadcast) in ipv4_interfaces() {
            // 기본 인터페이스 1개만 쓰면 VPN utun 쪽으로 나가는 것을 실측 (4.2 규칙 1)
            let _ = SockRef::from(self.socket.as_ref()).set_multicast_if_v4(&ip);
            let _ = self
                .socket
                .send_to(&data, (MULTICAST_GROUP, DISCOVERY_PORT))
                .await;
            let _ = self.socket.send_to(&data, (broadcast, DISCOVERY_PORT)).await;
        }
    }

    // TTL(15초) 지난 항목을 제거한 스냅샷을 alias 순으로 반환
    pub fn devices(&self) -> Vec<Device> {
        let mut map = self.devices.lock().unwrap();
        map.retain(|_, dev| dev.last_seen.elapsed() <= DEVICE_TTL);
        let mut list: Vec<Device> = map.values().cloned().collect();
        list.sort_by(|a, b| a.info.alias.cmp(&b.info.alias));
        list
    }

    fn spawn_read_loop(&self) {
        let socket = self.socket.clone();
        let devices = self.devices.clone();
        let self_info = self.self_info.clone();
        tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            loop {
                let Ok((n, src)) = socket.recv_from(&mut buf).await else {
                    return;
                };
                let Some(ann) = Announcement::decode(&buf[..n]) else {
                    continue;
                };
                // 내가 보낸 것이 되돌아온 경우 (4.2 규칙 3)
                if ann.info.fingerprint == self_info.fingerprint {
                    continue;
                }
                devices.lock().unwrap().insert(
                    ann.info.fingerprint.clone(),
                    Device {
                        info: ann.info.clone(),
                        ip: src.ip(),
                        last_seen: Instant::now(),
                    },
                );
                if ann.announce {
                    let reply = serde_json::to_vec(&Announcement::new(self_info.clone(), false))
                        .unwrap_or_default();
                    let _ = socket.send_to(&reply, src).await;
                }
            }
        });
    }

    fn spawn_announce_loop(&self) {
        let d = Discoverer {
            self_info: self.self_info.clone(),
            socket: self.socket.clone(),
            devices: self.devices.clone(),
        };
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(ANNOUNCE_INTERVAL);
            ticker.tick().await;
            loop {
                ticker.tick().await;
                d.announce().await;
            }
        });
    }
}

// (인터페이스 IPv4 주소, 실제 넷마스크 기반 브로드캐스트 주소) 목록
fn ipv4_interfaces() -> Vec<(Ipv4Addr, Ipv4Addr)> {
    let Ok(addrs) = if_addrs::get_if_addrs() else {
        return Vec::new();
    };
    addrs
        .into_iter()
        .filter(|a| a.is_loopback() == false)
        .filter_map(|a| match a.addr {
            if_addrs::IfAddr::V4(v4) => {
                let broadcast = v4.broadcast.unwrap_or_else(|| {
                    Ipv4Addr::from(u32::from(v4.ip) | !u32::from(v4.netmask))
                });
                Some((v4.ip, broadcast))
            }
            _ => None,
        })
        .collect()
}
