// 앱(P3-2)용 FRB 표면 — core를 노드 1개(수신 서버+탐색) 단위로 묶어 노출한다.
// tokio 런타임은 FRB 내장 런타임을 그대로 쓰므로 수명 관리 대상은 노드뿐이다.
use crate::core::discovery::{Device, DevicesChangedFn, Discoverer};
use crate::core::protocol::{FileMeta, PeerInfo};
use crate::core::security::{Identity, TrustStore};
use crate::core::transfer::recv::{ApprovalFn, Receiver, SavedFn, TransferRequest};
use crate::core::transfer::send::{exchange_info as core_exchange_info, ProgressFn, Sender};
use crate::frb_generated::StreamSink;
use anyhow::{Context, Result};
use flutter_rust_bridge::DartFnFuture;
use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;

pub struct NodeConfig {
    pub base_dir: String,
    pub save_dir: String,
    pub alias: String,
    pub device_type: String,
}

pub struct NodeStatus {
    pub port: u16,
    pub fingerprint: String,
}

#[derive(Clone)]
pub struct DeviceSnapshot {
    pub alias: String,
    pub device_type: String,
    pub fingerprint: String,
    pub ip: String,
    pub port: u16,
}

pub struct FileItem {
    pub id: String,
    pub name: String,
    pub size: i64,
}

pub struct ApprovalRequest {
    pub sender_alias: String,
    pub sender_fingerprint: String,
    pub is_new_device: bool,
    pub files: Vec<FileItem>,
}

#[derive(Clone)]
pub struct SavedFileEvent {
    pub path: String,
    pub from_alias: String,
}

pub struct TrustedDeviceView {
    pub fingerprint: String,
    pub alias: String,
    pub trusted_at: String,
}

pub struct SendTarget {
    pub ip: String,
    pub port: u16,
    pub fingerprint: String,
    pub alias: String,
}

// 필드 있는 enum은 FRB가 freezed 의존을 요구해 평탄 구조체로 둔다
#[derive(Clone, Copy, PartialEq)]
pub enum SendPhase {
    WaitingApproval,
    Uploading,
    Done,
    Failed,
    Canceled,
}

#[derive(Clone)]
pub struct SendEvent {
    pub phase: SendPhase,
    pub file_index: u32,
    pub file_count: u32,
    pub file_name: String,
    pub sent_bytes: i64,
    pub total_bytes: i64,
    pub message: Option<String>,
}

impl SendEvent {
    fn of(phase: SendPhase) -> SendEvent {
        SendEvent {
            phase,
            file_index: 0,
            file_count: 0,
            file_name: String::new(),
            sent_bytes: 0,
            total_bytes: 0,
            message: None,
        }
    }

    fn failed(message: String) -> SendEvent {
        SendEvent {
            message: Some(message),
            ..SendEvent::of(SendPhase::Failed)
        }
    }
}

struct Node {
    self_info: PeerInfo,
    trust: Arc<Mutex<TrustStore>>,
    receiver: Receiver,
    discoverer: Discoverer,
    device_tx: broadcast::Sender<Vec<DeviceSnapshot>>,
    saved_tx: broadcast::Sender<SavedFileEvent>,
    last_devices: Arc<Mutex<Vec<DeviceSnapshot>>>,
}

static NODE: Mutex<Option<Arc<Node>>> = Mutex::new(None);
// 동시 1건 송신(R4) — 진행 중 작업의 중단 핸들
static SENDING: Mutex<Option<tokio::task::AbortHandle>> = Mutex::new(None);

fn current() -> Result<Arc<Node>> {
    NODE.lock()
        .unwrap()
        .clone()
        .context("노드가 시작되지 않았습니다")
}

fn snapshot_of(device: &Device) -> DeviceSnapshot {
    DeviceSnapshot {
        alias: device.info.alias.clone(),
        device_type: device.info.device_type.clone(),
        fingerprint: device.info.fingerprint.clone(),
        ip: device.ip.to_string(),
        port: device.info.port,
    }
}

fn approval_request_of(req: TransferRequest) -> ApprovalRequest {
    let mut files: Vec<FileItem> = req
        .files
        .into_iter()
        .map(|(id, meta)| FileItem {
            id,
            name: meta.name,
            size: meta.size as i64,
        })
        .collect();
    files.sort_by(|a, b| a.id.cmp(&b.id));
    ApprovalRequest {
        sender_alias: req.sender.alias,
        sender_fingerprint: req.sender.fingerprint,
        is_new_device: req.is_new_device,
        files,
    }
}

pub async fn node_start(
    config: NodeConfig,
    on_approval: impl Fn(ApprovalRequest) -> DartFnFuture<bool> + Send + Sync + 'static,
) -> Result<NodeStatus> {
    node_stop().await;

    let base_dir = Path::new(&config.base_dir);
    std::fs::create_dir_all(&config.save_dir)?;
    let identity = Identity::load_or_create(base_dir)?;
    let trust = Arc::new(Mutex::new(TrustStore::open(base_dir)?));
    let mut self_info = PeerInfo {
        alias: config.alias,
        device_type: config.device_type,
        fingerprint: identity.fingerprint.clone(),
        port: 0,
    };

    let on_approval = Arc::new(on_approval);
    let approval: ApprovalFn = Arc::new(move |req| {
        let cb = on_approval.clone();
        Box::pin(async move { cb(approval_request_of(req)).await })
    });

    let (saved_tx, _) = broadcast::channel(64);
    let saved_out = saved_tx.clone();
    let on_saved: SavedFn = Arc::new(move |saved| {
        let _ = saved_out.send(SavedFileEvent {
            path: saved.path.to_string_lossy().to_string(),
            from_alias: saved.from,
        });
    });

    let receiver = Receiver::start(
        &identity,
        trust.clone(),
        Path::new(&config.save_dir),
        self_info.clone(),
        approval,
        Some(on_saved),
        None,
    )
    .await?;
    self_info.port = receiver.port();

    let (device_tx, _) = broadcast::channel(64);
    let device_out = device_tx.clone();
    let last_devices = Arc::new(Mutex::new(Vec::new()));
    let last_out = last_devices.clone();
    let on_changed: DevicesChangedFn = Arc::new(move |devices| {
        let snapshot: Vec<DeviceSnapshot> = devices.iter().map(snapshot_of).collect();
        *last_out.lock().unwrap() = snapshot.clone();
        let _ = device_out.send(snapshot);
    });
    let discoverer = Discoverer::start(self_info.clone(), Some(on_changed)).await?;

    let status = NodeStatus {
        port: self_info.port,
        fingerprint: identity.fingerprint.clone(),
    };
    *NODE.lock().unwrap() = Some(Arc::new(Node {
        self_info,
        trust,
        receiver,
        discoverer,
        device_tx,
        saved_tx,
        last_devices,
    }));
    Ok(status)
}

pub async fn node_stop() {
    let node = NODE.lock().unwrap().take();
    if let Some(node) = node {
        node.receiver.stop();
        node.discoverer.stop();
    }
}

pub async fn node_announce() -> Result<()> {
    current()?.discoverer.announce().await;
    Ok(())
}

// 구독 즉시 현재 목록을 1회 방출한다 — node_start와 구독 사이의 발견 누락 방지
pub async fn node_device_events(sink: StreamSink<Vec<DeviceSnapshot>>) -> Result<()> {
    let node = current()?;
    let mut rx = node.device_tx.subscribe();
    let _ = sink.add(node.last_devices.lock().unwrap().clone());
    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(list) => {
                    if sink.add(list).is_err() {
                        return;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => return,
            }
        }
    });
    Ok(())
}

pub async fn node_saved_events(sink: StreamSink<SavedFileEvent>) -> Result<()> {
    let node = current()?;
    let mut rx = node.saved_tx.subscribe();
    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(event) => {
                    if sink.add(event).is_err() {
                        return;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => return,
            }
        }
    });
    Ok(())
}

pub fn trust_list() -> Result<Vec<TrustedDeviceView>> {
    let node = current()?;
    let list = node
        .trust
        .lock()
        .unwrap()
        .all()
        .into_iter()
        .map(|(fingerprint, dev)| TrustedDeviceView {
            fingerprint,
            alias: dev.alias,
            trusted_at: dev.trusted_at,
        })
        .collect();
    Ok(list)
}

pub fn trust_contains(fingerprint: String) -> Result<bool> {
    Ok(current()?.trust.lock().unwrap().contains(&fingerprint))
}

pub fn trust_add(fingerprint: String, alias: String) -> Result<()> {
    current()?.trust.lock().unwrap().add(&fingerprint, &alias)
}

pub fn trust_remove(fingerprint: String) -> Result<()> {
    current()?.trust.lock().unwrap().remove(&fingerprint)
}

// IP 직접 입력 폴백 (4.2) — 응답 지문·TLS 지문 자기일치 검증은 core가 수행
pub async fn manual_exchange_info(address: String, port: u16) -> Result<DeviceSnapshot> {
    let node = current()?;
    let info = core_exchange_info(&format!("{address}:{port}"), &node.self_info).await?;
    Ok(DeviceSnapshot {
        alias: info.alias,
        device_type: info.device_type,
        fingerprint: info.fingerprint,
        ip: address,
        port: info.port,
    })
}

fn send_failure_message(e: &anyhow::Error) -> String {
    let chain = format!("{e:#}");
    if chain.contains("지문 불일치") {
        return "기기 지문이 광고된 값과 다릅니다 — 연결을 차단했습니다".to_string();
    }
    chain
}

// 전송 1회 전체(prepare → 순차 업로드)를 실행하며 진행 이벤트를 방출한다.
// 종료 이벤트는 Done/Failed/Canceled 중 정확히 1개.
pub async fn send_files(target: SendTarget, paths: Vec<String>, sink: StreamSink<SendEvent>) {
    if SENDING.lock().unwrap().is_some() {
        let _ = sink.add(SendEvent::failed("전송이 이미 진행 중입니다".to_string()));
        return;
    }
    let node = match current() {
        Ok(node) => node,
        Err(e) => {
            let _ = sink.add(SendEvent::failed(e.to_string()));
            return;
        }
    };

    let mut metas = HashMap::new();
    let mut items: Vec<(String, String, FileMeta)> = Vec::new();
    for (i, path) in paths.iter().enumerate() {
        let size = match std::fs::metadata(path) {
            Ok(meta) => meta.len(),
            Err(_) => {
                let _ = sink.add(SendEvent::failed(format!("읽을 수 없습니다: {path}")));
                return;
            }
        };
        let name = Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| path.clone());
        let id = format!("f{}", i + 1);
        let meta = FileMeta {
            name,
            size,
            mime: "application/octet-stream".to_string(),
        };
        metas.insert(id.clone(), meta.clone());
        items.push((id, path.clone(), meta));
    }
    let total_bytes: u64 = items.iter().map(|(_, _, m)| m.size).sum();
    let file_count = items.len() as u32;

    let addr = format!("{}:{}", target.ip, target.port);
    let session_slot: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let job_slot = session_slot.clone();
    let job_sink = sink.clone();
    let job_addr = addr.clone();
    let job_fingerprint = target.fingerprint.clone();
    let self_info = node.self_info.clone();

    let job = tokio::spawn(async move {
        let sender = Sender::new(&job_addr, &job_fingerprint, self_info);
        let _ = job_sink.add(SendEvent::of(SendPhase::WaitingApproval));
        let session = sender.prepare_upload(metas).await?;
        *job_slot.lock().unwrap() = Some(session.session_id.clone());

        let last_emitted = Arc::new(AtomicU64::new(0));
        let mut completed: u64 = 0;
        for (i, (file_id, path, meta)) in items.iter().enumerate() {
            let _ = job_sink.add(SendEvent {
                file_index: i as u32,
                file_count,
                file_name: meta.name.clone(),
                sent_bytes: completed as i64,
                total_bytes: total_bytes as i64,
                ..SendEvent::of(SendPhase::Uploading)
            });
            let progress_sink = job_sink.clone();
            let emitted = last_emitted.clone();
            let (base, size, name) = (completed, meta.size, meta.name.clone());
            let index = i as u32;
            // 청크마다 FFI를 건너지 않도록 1MB 단위로만 방출
            let on_progress: ProgressFn = Arc::new(move |sent_in_file| {
                let overall = base + sent_in_file;
                if overall - emitted.load(Ordering::Relaxed) >= 1 << 20 || sent_in_file == size {
                    emitted.store(overall, Ordering::Relaxed);
                    let _ = progress_sink.add(SendEvent {
                        file_index: index,
                        file_count,
                        file_name: name.clone(),
                        sent_bytes: overall as i64,
                        total_bytes: total_bytes as i64,
                        ..SendEvent::of(SendPhase::Uploading)
                    });
                }
            });
            let uploaded = sender
                .upload_file(
                    &session.session_id,
                    file_id,
                    &session.tokens[file_id],
                    Path::new(path),
                    meta.size,
                    Some(on_progress),
                )
                .await;
            if let Err(e) = uploaded {
                sender.cancel(&session.session_id).await;
                return Err(e);
            }
            completed += meta.size;
        }
        Ok(())
    });

    *SENDING.lock().unwrap() = Some(job.abort_handle());
    let result = job.await;
    SENDING.lock().unwrap().take();

    match result {
        Ok(Ok(())) => {
            let _ = sink.add(SendEvent::of(SendPhase::Done));
        }
        Ok(Err(e)) => {
            let _ = sink.add(SendEvent::failed(send_failure_message(&e)));
        }
        Err(join) if join.is_cancelled() => {
            // 중단 시 수신 측 세션도 정리한다 (4.3 cancel)
            let session = session_slot.lock().unwrap().clone();
            if let Some(session_id) = session {
                Sender::new(&addr, &target.fingerprint, node.self_info.clone())
                    .cancel(&session_id)
                    .await;
            }
            let _ = sink.add(SendEvent::of(SendPhase::Canceled));
        }
        Err(join) => {
            let _ = sink.add(SendEvent::failed(format!("전송 작업 비정상 종료: {join}")));
        }
    }
}

pub fn send_cancel() {
    if let Some(job) = SENDING.lock().unwrap().take() {
        job.abort();
    }
}
