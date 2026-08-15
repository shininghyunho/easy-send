// 4.3 송신 — prepare-upload → 파일별 순차 업로드. TLS는 4.4의 지문 검증을 강제한다.
use crate::core::protocol::{
    FileMeta, PeerInfo, PrepareUploadRequest, PrepareUploadResponse, API_PREFIX,
};
use crate::core::security::fingerprint_of;
use anyhow::{anyhow, bail, Context, Result};
use futures_util::TryStreamExt;
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full, StreamBody};
use hyper::body::{Bytes, Frame};
use hyper::{Method, Request, StatusCode};
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

pub fn status_message(code: u16) -> String {
    match code {
        403 => "수신자가 거절했습니다".to_string(),
        408 => "승인 대기 시간(60초)을 초과했습니다".to_string(),
        409 => "수신자가 다른 전송을 진행 중입니다 (busy)".to_string(),
        _ => format!("수신 측 오류 (HTTP {code})"),
    }
}

// 상대가 제시한 인증서 지문이 광고된 fingerprint와 다르면 즉시 연결 종료 (4.4 검증 1단계).
// expected가 None이면 지문을 캡처만 한다 (IP 직접 입력 /info 교환용 — 자기일치 검증은 호출부에서).
#[derive(Debug)]
struct FingerprintVerifier {
    expected: Option<String>,
    captured: Mutex<Option<String>>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for FingerprintVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        let observed = fingerprint_of(end_entity.as_ref());
        *self.captured.lock().unwrap() = Some(observed.clone());
        if let Some(expected) = &self.expected {
            if observed != *expected {
                return Err(rustls::Error::General(format!(
                    "인증서 지문 불일치: 광고된 기기가 아닙니다 ({}…)",
                    &observed[..16]
                )));
            }
        }
        Ok(ServerCertVerified::assertion())
    }

    // CA 검증만 생략하고 핸드셰이크 서명 검증은 유지한다 — 인증서만 복제한 MITM 차단
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

type HttpsClient = Client<hyper_rustls::HttpsConnector<HttpConnector>, BoxBody<Bytes, std::io::Error>>;

fn client_for(expected: Option<String>) -> (HttpsClient, Arc<FingerprintVerifier>) {
    let verifier = Arc::new(FingerprintVerifier {
        expected,
        captured: Mutex::new(None),
        provider: Arc::new(rustls::crypto::ring::default_provider()),
    });
    let tls = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier.clone())
        .with_no_client_auth();
    let connector = hyper_rustls::HttpsConnectorBuilder::new()
        .with_tls_config(tls)
        .https_only()
        .enable_http1()
        .build();
    (Client::builder(TokioExecutor::new()).build(connector), verifier)
}

fn empty_body() -> BoxBody<Bytes, std::io::Error> {
    Full::new(Bytes::new()).map_err(std::io::Error::other).boxed()
}

fn json_body<T: serde::Serialize>(value: &T) -> Result<BoxBody<Bytes, std::io::Error>> {
    let bytes = serde_json::to_vec(value)?;
    Ok(Full::from(bytes).map_err(std::io::Error::other).boxed())
}

// IP 직접 입력 폴백 (4.2). 응답 fingerprint가 TLS 인증서 지문과 일치해야 신뢰한다.
pub async fn exchange_info(addr: &str, self_info: &PeerInfo) -> Result<PeerInfo> {
    let (client, verifier) = client_for(None);
    let req = Request::builder()
        .method(Method::POST)
        .uri(format!("https://{addr}{API_PREFIX}/info"))
        .header(hyper::header::CONTENT_TYPE, "application/json")
        .body(json_body(self_info)?)?;
    let res = client.request(req).await.context("IP 직접 연결 실패")?;
    if res.status() != StatusCode::OK {
        bail!(status_message(res.status().as_u16()));
    }
    let body = res.into_body().collect().await?.to_bytes();
    let info: PeerInfo = serde_json::from_slice(&body)?;
    let observed = verifier.captured.lock().unwrap().clone();
    if Some(&info.fingerprint) != observed.as_ref() {
        bail!("응답 fingerprint가 TLS 인증서 지문과 다릅니다");
    }
    Ok(info)
}

// 파일 1개 안에서의 누적 송신 바이트
pub type ProgressFn = Arc<dyn Fn(u64) + Send + Sync>;

pub struct Sender {
    addr: String,
    client: HttpsClient,
    self_info: PeerInfo,
}

impl Sender {
    pub fn new(addr: &str, expected_fingerprint: &str, self_info: PeerInfo) -> Sender {
        let (client, _) = client_for(Some(expected_fingerprint.to_string()));
        Sender {
            addr: addr.to_string(),
            client,
            self_info,
        }
    }

    fn url(&self, path: &str, query: &str) -> String {
        format!("https://{}{API_PREFIX}{path}{query}", self.addr)
    }

    pub async fn prepare_upload(
        &self,
        files: HashMap<String, FileMeta>,
    ) -> Result<PrepareUploadResponse> {
        let req = Request::builder()
            .method(Method::POST)
            .uri(self.url("/prepare-upload", ""))
            .header(hyper::header::CONTENT_TYPE, "application/json")
            .body(json_body(&PrepareUploadRequest {
                info: self.self_info.clone(),
                files,
            })?)?;
        let res = self.client.request(req).await?;
        if res.status() != StatusCode::OK {
            bail!(status_message(res.status().as_u16()));
        }
        let body = res.into_body().collect().await?.to_bytes();
        Ok(serde_json::from_slice(&body)?)
    }

    // 바디는 파일 원본 바이트 그대로 (multipart 없음, 4.3)
    pub async fn upload_file(
        &self,
        session_id: &str,
        file_id: &str,
        token: &str,
        path: &Path,
        size: u64,
        on_progress: Option<ProgressFn>,
    ) -> Result<()> {
        let file = tokio::fs::File::open(path).await?;
        let sent = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let stream = tokio_util::io::ReaderStream::new(file).map_ok(move |chunk| {
            if let Some(cb) = &on_progress {
                let total = sent
                    .fetch_add(chunk.len() as u64, std::sync::atomic::Ordering::Relaxed)
                    + chunk.len() as u64;
                cb(total);
            }
            Frame::data(chunk)
        });
        let req = Request::builder()
            .method(Method::POST)
            .uri(self.url(
                "/upload",
                &format!("?sessionId={session_id}&fileId={file_id}&token={token}"),
            ))
            .header(hyper::header::CONTENT_LENGTH, size)
            .body(BoxBody::new(StreamBody::new(stream)))?;
        let res = self.client.request(req).await?;
        if res.status() != StatusCode::OK {
            return Err(anyhow!(status_message(res.status().as_u16())));
        }
        Ok(())
    }

    pub async fn cancel(&self, session_id: &str) {
        let req = Request::builder()
            .method(Method::POST)
            .uri(self.url("/cancel", &format!("?sessionId={session_id}")))
            .body(empty_body());
        if let Ok(req) = req {
            let _ = self.client.request(req).await;
        }
    }
}
