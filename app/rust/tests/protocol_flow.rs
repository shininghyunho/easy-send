// PRD 4.3 세션 상태머신·에러 표 전 경로 검증 — Dart core의 M2 테스트망에 대응하는
// Rust 재구현용 회귀망. 인터랩(Go CLI·앱)으로는 에러 경로 재현이 느리거나 불안정하다.
use rust_lib_easy_send_app::core::protocol::{FileMeta, PeerInfo};
use rust_lib_easy_send_app::core::security::{Identity, TrustStore};
use rust_lib_easy_send_app::core::transfer::recv::Receiver;
use rust_lib_easy_send_app::core::transfer::send::Sender;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tempfile::TempDir;

struct TestReceiver {
    receiver: Receiver,
    fingerprint: String,
    save_dir: TempDir,
    config_dir: TempDir,
}

async fn start_receiver(approve: bool, approval_timeout: Option<Duration>) -> TestReceiver {
    let config_dir = TempDir::new().unwrap();
    let save_dir = TempDir::new().unwrap();
    let identity = Identity::load_or_create(config_dir.path()).unwrap();
    let trust = TrustStore::open(config_dir.path()).unwrap();
    let fingerprint = identity.fingerprint.clone();
    let self_info = PeerInfo {
        alias: "rx".to_string(),
        device_type: "desktop".to_string(),
        fingerprint: fingerprint.clone(),
        port: 0,
    };
    let receiver = Receiver::start(
        &identity,
        trust,
        save_dir.path(),
        self_info,
        Arc::new(move |_req| {
            Box::pin(async move {
                if approve {
                    true
                } else {
                    false
                }
            })
        }),
        None,
        approval_timeout,
    )
    .await
    .unwrap();
    TestReceiver {
        receiver,
        fingerprint,
        save_dir,
        config_dir,
    }
}

fn sender_for(rx: &TestReceiver) -> (Sender, TempDir) {
    let config_dir = TempDir::new().unwrap();
    let identity = Identity::load_or_create(config_dir.path()).unwrap();
    let self_info = PeerInfo {
        alias: "tx".to_string(),
        device_type: "desktop".to_string(),
        fingerprint: identity.fingerprint,
        port: 53318,
    };
    (
        Sender::new(
            &format!("127.0.0.1:{}", rx.receiver.port()),
            &rx.fingerprint,
            self_info,
        ),
        config_dir,
    )
}

fn write_file(dir: &Path, name: &str, content: &[u8]) -> std::path::PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, content).unwrap();
    path
}

fn meta_of(name: &str, content: &[u8]) -> FileMeta {
    FileMeta {
        name: name.to_string(),
        size: content.len() as u64,
        mime: "application/octet-stream".to_string(),
    }
}

// 승인 → 2파일 순차 업로드 → 바이트 일치 + 충돌 시 "(1)" 부여 + TOFU 저장 (4.3 정상 경로, 4.4)
#[tokio::test]
async fn approve_two_files_saves_bytes_and_records_trust() {
    let rx = start_receiver(true, None).await;
    let (sender, tx_dir) = sender_for(&rx);

    let a = vec![0xABu8; 300_000];
    let b = b"hello easy-send".to_vec();
    let path_a = write_file(tx_dir.path(), "a.bin", &a);
    let path_b = write_file(tx_dir.path(), "b.txt", &b);
    // 수신 폴더에 같은 이름을 미리 두면 덮어쓰지 않고 "a (1).bin"이 된다
    write_file(rx.save_dir.path(), "a.bin", b"pre-existing");

    let files = HashMap::from([
        ("f1".to_string(), meta_of("a.bin", &a)),
        ("f2".to_string(), meta_of("b.txt", &b)),
    ]);
    let session = sender.prepare_upload(files).await.unwrap();
    sender
        .upload_file(&session.session_id, "f1", &session.tokens["f1"], &path_a, a.len() as u64)
        .await
        .unwrap();
    sender
        .upload_file(&session.session_id, "f2", &session.tokens["f2"], &path_b, b.len() as u64)
        .await
        .unwrap();

    assert_eq!(std::fs::read(rx.save_dir.path().join("a (1).bin")).unwrap(), a);
    assert_eq!(std::fs::read(rx.save_dir.path().join("b.txt")).unwrap(), b);
    let trusted = std::fs::read_to_string(rx.config_dir.path().join("trusted.json")).unwrap();
    assert!(trusted.contains("tx"));
}

// 거절 = 403 (4.3 에러 표)
#[tokio::test]
async fn reject_returns_403() {
    let rx = start_receiver(false, None).await;
    let (sender, _tx_dir) = sender_for(&rx);
    let err = sender
        .prepare_upload(HashMap::from([("f1".to_string(), meta_of("x", b"x"))]))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("거절"), "{err:#}");
}

// 승인 대기 초과 = 408 (4.3 에러 표) — 타임아웃 파라미터로 단축해 검증
#[tokio::test]
async fn approval_timeout_returns_408() {
    let config_dir = TempDir::new().unwrap();
    let save_dir = TempDir::new().unwrap();
    let identity = Identity::load_or_create(config_dir.path()).unwrap();
    let trust = TrustStore::open(config_dir.path()).unwrap();
    let self_info = PeerInfo {
        alias: "rx".to_string(),
        device_type: "desktop".to_string(),
        fingerprint: identity.fingerprint.clone(),
        port: 0,
    };
    let rx = TestReceiver {
        fingerprint: identity.fingerprint.clone(),
        receiver: Receiver::start(
            &identity,
            trust,
            save_dir.path(),
            self_info,
            Arc::new(|_req| Box::pin(futures_util::future::pending())),
            None,
            Some(Duration::from_millis(300)),
        )
        .await
        .unwrap(),
        save_dir,
        config_dir,
    };
    let (sender, _tx_dir) = sender_for(&rx);
    let err = sender
        .prepare_upload(HashMap::from([("f1".to_string(), meta_of("x", b"x"))]))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("초과"), "{err:#}");
}

// pending 중 새 prepare-upload = 409 busy (R4 동시 1세션)
#[tokio::test]
async fn concurrent_prepare_returns_409() {
    let rx = start_receiver(true, Some(Duration::from_secs(2))).await;
    // 첫 요청을 pending에 묶어두기 위해 승인을 지연시키는 수신자를 따로 만든다
    let config_dir = TempDir::new().unwrap();
    let save_dir = TempDir::new().unwrap();
    let identity = Identity::load_or_create(config_dir.path()).unwrap();
    let trust = TrustStore::open(config_dir.path()).unwrap();
    let self_info = PeerInfo {
        alias: "rx2".to_string(),
        device_type: "desktop".to_string(),
        fingerprint: identity.fingerprint.clone(),
        port: 0,
    };
    let slow_rx = TestReceiver {
        fingerprint: identity.fingerprint.clone(),
        receiver: Receiver::start(
            &identity,
            trust,
            save_dir.path(),
            self_info,
            Arc::new(|_req| {
                Box::pin(async {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    true
                })
            }),
            None,
            None,
        )
        .await
        .unwrap(),
        save_dir,
        config_dir,
    };
    drop(rx);

    let (first, _d1) = sender_for(&slow_rx);
    let (second, _d2) = sender_for(&slow_rx);
    let files = HashMap::from([("f1".to_string(), meta_of("x", b"x"))]);
    let first_files = files.clone();
    let pending = tokio::spawn(async move { first.prepare_upload(first_files).await });
    tokio::time::sleep(Duration::from_millis(200)).await;
    let err = second.prepare_upload(files).await.unwrap_err();
    assert!(err.to_string().contains("busy"), "{err:#}");
    assert!(pending.await.unwrap().is_ok());
}

// 토큰 무효 = 404, 취소 후 업로드 = 404 (4.3 에러 표)
#[tokio::test]
async fn invalid_token_and_cancelled_session_return_404() {
    let rx = start_receiver(true, None).await;
    let (sender, tx_dir) = sender_for(&rx);
    let content = b"payload".to_vec();
    let path = write_file(tx_dir.path(), "x.bin", &content);
    let files = HashMap::from([("f1".to_string(), meta_of("x.bin", &content))]);

    let session = sender.prepare_upload(files.clone()).await.unwrap();
    let err = sender
        .upload_file(&session.session_id, "f1", "wrong-token", &path, content.len() as u64)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("404"), "{err:#}");

    sender.cancel(&session.session_id).await;
    let err = sender
        .upload_file(&session.session_id, "f1", &session.tokens["f1"], &path, content.len() as u64)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("404"), "{err:#}");
}

// 광고된 지문과 다른 인증서 = 연결 자체가 실패해야 한다 (4.4 검증 1단계)
#[tokio::test]
async fn fingerprint_mismatch_aborts_connection() {
    let rx = start_receiver(true, None).await;
    let other = TempDir::new().unwrap();
    let wrong_fp = Identity::load_or_create(other.path()).unwrap().fingerprint;
    let self_info = PeerInfo {
        alias: "tx".to_string(),
        device_type: "desktop".to_string(),
        fingerprint: wrong_fp.clone(),
        port: 53318,
    };
    let sender = Sender::new(&format!("127.0.0.1:{}", rx.receiver.port()), &wrong_fp, self_info);
    let result = sender
        .prepare_upload(HashMap::from([("f1".to_string(), meta_of("x", b"x"))]))
        .await;
    assert!(result.is_err());
}
