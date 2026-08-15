// 4.3 수신 — 세션 상태 머신 (idle→pending→sending, 동시 1세션 R4)
use crate::core::protocol::{
    FileMeta, PeerInfo, PrepareUploadRequest, PrepareUploadResponse, API_PREFIX, APPROVAL_TIMEOUT,
    SERVICE_PORT,
};
use crate::core::security::{Identity, TrustStore};
use anyhow::Result;
use futures_util::future::BoxFuture;
use http_body_util::{BodyExt, Full};
use hyper::body::{Bytes, Incoming};
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use rand::RngCore;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;

// 승인 다이얼로그에 보여줄 요청 내용
pub struct TransferRequest {
    pub sender: PeerInfo,
    pub files: HashMap<String, FileMeta>,
    pub is_new_device: bool,
}

// 승인 다이얼로그에 해당. 시간 안에 결과가 없으면 408 (4.3)
pub type ApprovalFn = Arc<dyn Fn(TransferRequest) -> BoxFuture<'static, bool> + Send + Sync>;

pub struct SavedFile {
    pub path: PathBuf,
    pub from: String,
}

pub type SavedFn = Arc<dyn Fn(SavedFile) + Send + Sync>;

enum State {
    Idle,
    Pending,
    Sending(Session),
}

struct Session {
    id: String,
    from_alias: String,
    files: HashMap<String, FileMeta>,
    tokens: HashMap<String, String>,
    received: HashSet<String>,
}

struct Shared {
    self_info: PeerInfo,
    save_dir: PathBuf,
    on_approval: ApprovalFn,
    on_saved: Option<SavedFn>,
    approval_timeout: Duration,
    state: Mutex<State>,
    trust: Mutex<TrustStore>,
    port: u16,
}

pub struct Receiver {
    shared: Arc<Shared>,
}

impl Receiver {
    // 53318에 HTTPS 서버를 연다. 사용 중이면 임의 포트로 폴백 (4.1)
    pub async fn start(
        identity: &Identity,
        trust: TrustStore,
        save_dir: &Path,
        self_info: PeerInfo,
        on_approval: ApprovalFn,
        on_saved: Option<SavedFn>,
        approval_timeout: Option<Duration>,
    ) -> Result<Receiver> {
        let listener = match TcpListener::bind(("0.0.0.0", SERVICE_PORT)).await {
            Ok(l) => l,
            Err(_) => TcpListener::bind(("0.0.0.0", 0)).await?,
        };
        let port = listener.local_addr()?.port();
        let acceptor = TlsAcceptor::from(Arc::new(identity.server_config()?));

        let shared = Arc::new(Shared {
            self_info,
            save_dir: save_dir.to_path_buf(),
            on_approval,
            on_saved,
            approval_timeout: approval_timeout.unwrap_or(APPROVAL_TIMEOUT),
            state: Mutex::new(State::Idle),
            trust: Mutex::new(trust),
            port,
        });

        let accept_shared = shared.clone();
        tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = listener.accept().await else {
                    return;
                };
                let acceptor = acceptor.clone();
                let shared = accept_shared.clone();
                tokio::spawn(async move {
                    let Ok(tls) = acceptor.accept(tcp).await else {
                        return;
                    };
                    let service =
                        service_fn(move |req| route(shared.clone(), req));
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(TokioIo::new(tls), service)
                        .await;
                });
            }
        });
        Ok(Receiver { shared })
    }

    pub fn port(&self) -> u16 {
        self.shared.port
    }
}

async fn route(shared: Arc<Shared>, req: Request<Incoming>) -> Result<Response<Full<Bytes>>> {
    let path = req.uri().path().to_string();
    if req.method() != Method::POST {
        return status(StatusCode::NOT_FOUND);
    }
    let result = match path.strip_prefix(API_PREFIX) {
        Some("/info") => handle_info(shared, req).await,
        Some("/prepare-upload") => handle_prepare(shared, req).await,
        Some("/upload") => handle_upload(shared, req).await,
        Some("/cancel") => handle_cancel(shared, req).await,
        _ => status(StatusCode::NOT_FOUND),
    };
    match result {
        Ok(res) => Ok(res),
        Err(_) => status(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

async fn handle_info(shared: Arc<Shared>, req: Request<Incoming>) -> Result<Response<Full<Bytes>>> {
    let _ = req.into_body().collect().await;
    // self_info.port는 바인딩 전 값(0)일 수 있어 실제 포트로 바꿔 응답한다
    let mut info = shared.self_info.clone();
    info.port = shared.port;
    json(&info)
}

async fn handle_prepare(
    shared: Arc<Shared>,
    req: Request<Incoming>,
) -> Result<Response<Full<Bytes>>> {
    let body = req.into_body().collect().await?.to_bytes();
    let Ok(prepare) = serde_json::from_slice::<PrepareUploadRequest>(&body) else {
        return status(StatusCode::BAD_REQUEST);
    };
    if prepare.files.is_empty() {
        return status(StatusCode::BAD_REQUEST);
    }

    {
        let mut state = shared.state.lock().unwrap();
        match *state {
            State::Idle => *state = State::Pending,
            _ => return status(StatusCode::CONFLICT),
        }
    }

    let request = TransferRequest {
        sender: prepare.info.clone(),
        files: prepare.files.clone(),
        is_new_device: shared
            .trust
            .lock()
            .unwrap()
            .contains(&prepare.info.fingerprint)
            == false,
    };
    let approved =
        tokio::time::timeout(shared.approval_timeout, (shared.on_approval)(request)).await;
    match approved {
        Err(_) => {
            *shared.state.lock().unwrap() = State::Idle;
            return status(StatusCode::REQUEST_TIMEOUT);
        }
        Ok(false) => {
            *shared.state.lock().unwrap() = State::Idle;
            return status(StatusCode::FORBIDDEN);
        }
        Ok(true) => {}
    }

    let _ = shared
        .trust
        .lock()
        .unwrap()
        .add(&prepare.info.fingerprint, &prepare.info.alias);

    let session = Session {
        id: random_hex16(),
        from_alias: prepare.info.alias.clone(),
        files: prepare.files.clone(),
        tokens: prepare.files.keys().map(|id| (id.clone(), random_hex16())).collect(),
        received: HashSet::new(),
    };
    let response = PrepareUploadResponse {
        session_id: session.id.clone(),
        tokens: session.tokens.clone(),
    };
    *shared.state.lock().unwrap() = State::Sending(session);
    json(&response)
}

async fn handle_upload(
    shared: Arc<Shared>,
    req: Request<Incoming>,
) -> Result<Response<Full<Bytes>>> {
    let query: HashMap<String, String> = req
        .uri()
        .query()
        .map(query_params)
        .unwrap_or_default();
    let (session_id, file_id, token) = (
        query.get("sessionId").cloned().unwrap_or_default(),
        query.get("fileId").cloned().unwrap_or_default(),
        query.get("token").cloned().unwrap_or_default(),
    );

    let (meta, from_alias) = {
        let state = shared.state.lock().unwrap();
        let State::Sending(session) = &*state else {
            return status(StatusCode::NOT_FOUND);
        };
        let valid = session.id == session_id
            && token.is_empty() == false
            && session.tokens.get(&file_id) == Some(&token)
            && session.received.contains(&file_id) == false;
        if valid == false {
            return status(StatusCode::NOT_FOUND);
        }
        (session.files[&file_id].clone(), session.from_alias.clone())
    };

    match save_body(&shared.save_dir, &meta, req.into_body()).await {
        Ok(path) => {
            let mut state = shared.state.lock().unwrap();
            if let State::Sending(session) = &mut *state {
                session.received.insert(file_id);
                if session.received.len() == session.files.len() {
                    *state = State::Idle;
                }
            }
            drop(state);
            if let Some(on_saved) = &shared.on_saved {
                on_saved(SavedFile { path, from: from_alias });
            }
            status(StatusCode::OK)
        }
        Err(_) => {
            // 수신 측 내부 오류(디스크 부족·크기 불일치)는 세션째 중단한다 (4.3 코드 500)
            *shared.state.lock().unwrap() = State::Idle;
            status(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

async fn handle_cancel(
    shared: Arc<Shared>,
    req: Request<Incoming>,
) -> Result<Response<Full<Bytes>>> {
    let query: HashMap<String, String> = req
        .uri()
        .query()
        .map(query_params)
        .unwrap_or_default();
    let session_id = query.get("sessionId").cloned().unwrap_or_default();
    let mut state = shared.state.lock().unwrap();
    if let State::Sending(session) = &*state {
        if session.id == session_id {
            *state = State::Idle;
            return status(StatusCode::OK);
        }
    }
    status(StatusCode::NOT_FOUND)
}

// 바디를 저장 폴더에 쓴다. 같은 이름이 있으면 "name (1).ext" 식 번호 부여 (덮어쓰기 금지, 4.3)
async fn save_body(save_dir: &Path, meta: &FileMeta, mut body: Incoming) -> Result<PathBuf> {
    // 경로 조작 차단 — 파일명 성분만 사용
    let name = Path::new(&meta.name)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "unnamed".to_string());
    let target = resolve_collision(save_dir, &name);

    let mut file = tokio::fs::File::create(&target).await?;
    let mut written: u64 = 0;
    let result: Result<()> = async {
        while let Some(frame) = body.frame().await {
            if let Some(data) = frame?.data_ref() {
                file.write_all(data).await?;
                written += data.len() as u64;
            }
        }
        file.flush().await?;
        // 크기 불일치 = 손상된 파일을 조용히 남기지 않고 즉시 실패시킨다
        anyhow::ensure!(written == meta.size, "크기 불일치: {written} != {}", meta.size);
        Ok(())
    }
    .await;
    if let Err(e) = result {
        let _ = tokio::fs::remove_file(&target).await;
        return Err(e);
    }
    Ok(target)
}

fn resolve_collision(dir: &Path, name: &str) -> PathBuf {
    let dot = name.rfind('.').filter(|&i| i > 0);
    let (stem, ext) = match dot {
        Some(i) => (&name[..i], &name[i..]),
        None => (name, ""),
    };
    let mut candidate = dir.join(name);
    let mut n = 1;
    while candidate.exists() {
        candidate = dir.join(format!("{stem} ({n}){ext}"));
        n += 1;
    }
    candidate
}

fn query_params(query: &str) -> HashMap<String, String> {
    query
        .split('&')
        .filter_map(|pair| {
            let (k, v) = pair.split_once('=')?;
            Some((url_decode(k), url_decode(v)))
        })
        .collect()
}

// 쿼리 값은 hex 토큰·세션 ID뿐이라 %XX와 + 만 풀면 충분하다
fn url_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                match u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    Ok(b) => {
                        out.push(b);
                        i += 3;
                    }
                    Err(_) => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

fn random_hex16() -> String {
    let mut buf = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut buf);
    hex::encode(buf)
}

fn status(code: StatusCode) -> Result<Response<Full<Bytes>>> {
    Ok(Response::builder().status(code).body(Full::default())?)
}

fn json<T: serde::Serialize>(value: &T) -> Result<Response<Full<Bytes>>> {
    Ok(Response::builder()
        .header(hyper::header::CONTENT_TYPE, "application/json")
        .body(Full::from(serde_json::to_vec(value)?))?)
}
