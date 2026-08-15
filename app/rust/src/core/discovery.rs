// 4.2 탐색 — 5초 멀티캐스트+서브넷 브로드캐스트 병행 announce, 유니캐스트 응답, 15초 TTL
use crate::core::protocol::{
    Announcement, PeerInfo, ANNOUNCE_INTERVAL, DEVICE_TTL, DISCOVERY_PORT, MULTICAST_GROUP,
};
use anyhow::Result;
use socket2::{Domain, Protocol, SockRef, Socket, Type};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::task::AbortHandle;

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

// 목록 변화(추가·정보 변경·TTL 제거) 시 전체 스냅샷을 전달
pub type DevicesChangedFn = Arc<dyn Fn(Vec<Device>) + Send + Sync>;

struct Inner {
    self_info: PeerInfo,
    devices: Mutex<HashMap<String, Device>>,
    // OS가 소켓을 닫으면(Android 백그라운드 전환 실측) None으로 돌아가고
    // announce 주기에서 재바인드로 자연 복구된다
    socket: Mutex<Option<Arc<UdpSocket>>>,
    read_task: Mutex<Option<AbortHandle>>,
    on_changed: Option<DevicesChangedFn>,
}

pub struct Discoverer {
    inner: Arc<Inner>,
    tasks: Vec<AbortHandle>,
}

impl Discoverer {
    // 53318 바인드(같은 호스트의 다른 피어와 공존을 위해 SO_REUSEPORT) 후
    // 수신 루프와 5초 announce 루프, 1초 TTL 정리 루프를 돌린다.
    pub async fn start(
        self_info: PeerInfo,
        on_changed: Option<DevicesChangedFn>,
    ) -> Result<Discoverer> {
        let inner = Arc::new(Inner {
            self_info,
            devices: Mutex::new(HashMap::new()),
            socket: Mutex::new(None),
            read_task: Mutex::new(None),
            on_changed,
        });
        bind(&inner)?;

        let announce_inner = inner.clone();
        let announce_task = tokio::spawn(async move {
            let mut ticker = tokio::time::interval(ANNOUNCE_INTERVAL);
            ticker.tick().await;
            loop {
                ticker.tick().await;
                announce(&announce_inner).await;
            }
        })
        .abort_handle();

        let prune_inner = inner.clone();
        let prune_task = tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(1));
            loop {
                ticker.tick().await;
                let removed = {
                    let mut map = prune_inner.devices.lock().unwrap();
                    let before = map.len();
                    map.retain(|_, dev| dev.last_seen.elapsed() <= DEVICE_TTL);
                    map.len() != before
                };
                if removed {
                    emit(&prune_inner);
                }
            }
        })
        .abort_handle();

        announce(&inner).await;
        Ok(Discoverer {
            inner,
            tasks: vec![announce_task, prune_task],
        })
    }

    // 즉시 announce 1회 — 시작 시와 UI 새로고침에서 호출
    pub async fn announce(&self) {
        announce(&self.inner).await;
    }

    // TTL(15초) 지난 항목을 제거한 스냅샷을 alias 순으로 반환
    pub fn devices(&self) -> Vec<Device> {
        let mut map = self.inner.devices.lock().unwrap();
        map.retain(|_, dev| dev.last_seen.elapsed() <= DEVICE_TTL);
        snapshot_of(&map)
    }

    pub fn stop(&self) {
        for task in &self.tasks {
            task.abort();
        }
        if let Some(read) = self.inner.read_task.lock().unwrap().take() {
            read.abort();
        }
        self.inner.socket.lock().unwrap().take();
    }
}

fn snapshot_of(map: &HashMap<String, Device>) -> Vec<Device> {
    let mut list: Vec<Device> = map.values().cloned().collect();
    list.sort_by(|a, b| a.info.alias.cmp(&b.info.alias));
    list
}

fn emit(inner: &Arc<Inner>) {
    if let Some(on_changed) = &inner.on_changed {
        let snapshot = snapshot_of(&inner.devices.lock().unwrap());
        on_changed(snapshot);
    }
}

// 소켓 생성 + 멀티캐스트 조인 + 수신 루프 기동. 이전 수신 루프는 교체한다.
fn bind(inner: &Arc<Inner>) -> Result<Arc<UdpSocket>> {
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

    let read_task = spawn_read_loop(inner, socket.clone());
    if let Some(old) = inner.read_task.lock().unwrap().replace(read_task) {
        old.abort();
    }
    *inner.socket.lock().unwrap() = Some(socket.clone());
    Ok(socket)
}

fn current_or_rebind(inner: &Arc<Inner>) -> Option<Arc<UdpSocket>> {
    if let Some(socket) = inner.socket.lock().unwrap().clone() {
        return Some(socket);
    }
    bind(inner).ok() // 실패 시 다음 announce 주기에 재시도
}

// 인터페이스를 순회하며 멀티캐스트+브로드캐스트로 이중 송신 (PRD 4.2 M4 개정)
async fn announce(inner: &Arc<Inner>) {
    let Some(socket) = current_or_rebind(inner) else {
        return;
    };
    let data = serde_json::to_vec(&Announcement::new(inner.self_info.clone(), true))
        .unwrap_or_default();
    for (ip, broadcast) in ipv4_interfaces() {
        // 기본 인터페이스 1개만 쓰면 VPN utun 쪽으로 나가는 것을 실측 (4.2 규칙 1)
        let _ = SockRef::from(socket.as_ref()).set_multicast_if_v4(&ip);
        let _ = socket.send_to(&data, (MULTICAST_GROUP, DISCOVERY_PORT)).await;
        let _ = socket.send_to(&data, (broadcast, DISCOVERY_PORT)).await;
    }
}

fn spawn_read_loop(inner: &Arc<Inner>, socket: Arc<UdpSocket>) -> AbortHandle {
    let inner = inner.clone();
    tokio::spawn(async move {
        let mut buf = [0u8; 4096];
        loop {
            let Ok((n, src)) = socket.recv_from(&mut buf).await else {
                // 소켓이 죽으면 비워서 announce 주기의 재바인드로 넘긴다
                let mut current = inner.socket.lock().unwrap();
                if let Some(held) = &*current {
                    if Arc::ptr_eq(held, &socket) {
                        current.take();
                    }
                }
                return;
            };
            let Some(ann) = Announcement::decode(&buf[..n]) else {
                continue;
            };
            // 내가 보낸 것이 되돌아온 경우 (4.2 규칙 3)
            if ann.info.fingerprint == inner.self_info.fingerprint {
                continue;
            }
            let changed = {
                let mut devices = inner.devices.lock().unwrap();
                let known = devices.get(&ann.info.fingerprint);
                let changed = match known {
                    None => true,
                    Some(dev) => {
                        dev.info.alias != ann.info.alias
                            || dev.info.port != ann.info.port
                            || dev.ip != src.ip()
                    }
                };
                devices.insert(
                    ann.info.fingerprint.clone(),
                    Device {
                        info: ann.info.clone(),
                        ip: src.ip(),
                        last_seen: Instant::now(),
                    },
                );
                changed
            };
            if changed {
                emit(&inner);
            }
            if ann.announce {
                let reply =
                    serde_json::to_vec(&Announcement::new(inner.self_info.clone(), false))
                        .unwrap_or_default();
                let _ = socket.send_to(&reply, src).await;
            }
        }
    })
    .abort_handle()
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
