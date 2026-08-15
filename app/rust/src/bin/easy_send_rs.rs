// easy-send Rust CLI 피어 — core 모듈의 독립 검증 하니스 (P3-1)
use anyhow::{bail, Context, Result};
use rust_lib_easy_send_app::core::discovery::{Device, Discoverer};
use rust_lib_easy_send_app::core::protocol::{FileMeta, PeerInfo, SERVICE_PORT, VERSION};
use rust_lib_easy_send_app::core::security::{Identity, TrustStore};
use rust_lib_easy_send_app::core::transfer::recv::{Receiver, SavedFile, TransferRequest};
use rust_lib_easy_send_app::core::transfer::send::{exchange_info, Sender};
use std::collections::HashMap;
use std::io::Write as _;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("ls") => cmd_ls(&args[1..]).await,
        Some("send") => cmd_send(&args[1..]).await,
        Some("recv") => cmd_recv(&args[1..]).await,
        _ => {
            usage();
            std::process::exit(2);
        }
    };
    if let Err(e) = result {
        eprintln!("오류: {e:#}");
        std::process::exit(1);
    }
}

fn usage() {
    eprintln!(
        "사용법:
  easy-send-rs ls [--wait 초]                발견된 기기 목록 (기본 3초 탐색)
  easy-send-rs send <파일...> --to <대상>    파일 전송 (대상 = alias 또는 IP[:포트])
  easy-send-rs recv [--dir 폴더]             수신 대기 (기본 저장 위치: 현재 폴더)"
    );
}

// Go CLI(~/.easy-send)와 같은 호스트에서 별개 기기로 보이도록 신원 폴더를 분리한다
fn config_dir() -> PathBuf {
    match std::env::var("HOME") {
        Ok(home) => Path::new(&home).join(".easy-send-rust"),
        Err(_) => PathBuf::from(".easy-send-rust"),
    }
}

fn self_info(alias: Option<String>, identity: &Identity, port: u16) -> PeerInfo {
    let alias = alias.unwrap_or_else(|| {
        gethostname::gethostname()
            .to_string_lossy()
            .trim_end_matches(".local")
            .to_string()
    });
    PeerInfo {
        alias,
        device_type: "desktop".to_string(),
        fingerprint: identity.fingerprint.clone(),
        port,
    }
}

// --flag 값 쌍과 위치 인자를 분리하는 최소 파서
fn parse_args(args: &[String], flags_with_value: &[&str]) -> (HashMap<String, String>, Vec<String>) {
    let mut flags = HashMap::new();
    let mut positional = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if let Some(name) = arg.strip_prefix("--") {
            if flags_with_value.contains(&name) && i + 1 < args.len() {
                flags.insert(name.to_string(), args[i + 1].clone());
                i += 2;
                continue;
            }
        }
        positional.push(arg.clone());
        i += 1;
    }
    (flags, positional)
}

async fn cmd_ls(args: &[String]) -> Result<()> {
    let (flags, _) = parse_args(args, &["alias", "wait"]);
    let wait: u64 = flags.get("wait").map_or(Ok(3), |w| w.parse())?;

    let identity = Identity::load_or_create(&config_dir())?;
    let d = Discoverer::start(self_info(flags.get("alias").cloned(), &identity, SERVICE_PORT)).await?;
    println!("발견된 기기 ({wait}초 탐색):");
    tokio::time::sleep(Duration::from_secs(wait)).await;
    let devices = d.devices();
    if devices.is_empty() {
        println!("  (없음)");
        return Ok(());
    }
    for (i, dev) in devices.iter().enumerate() {
        println!(
            "  {}. {:<24} {:<8} {}",
            i + 1,
            dev.info.alias,
            dev.info.device_type,
            dev.addr()
        );
    }
    Ok(())
}

async fn cmd_send(args: &[String]) -> Result<()> {
    let (flags, paths) = parse_args(args, &["to", "alias"]);
    let Some(to) = flags.get("to") else {
        bail!("사용법: easy-send-rs send <파일...> --to <대상>");
    };
    if paths.is_empty() {
        bail!("사용법: easy-send-rs send <파일...> --to <대상>");
    }
    for p in &paths {
        let meta = std::fs::metadata(p).with_context(|| format!("읽을 수 없습니다: {p}"))?;
        if meta.is_file() == false {
            bail!("파일이 아닙니다: {p}");
        }
    }

    let dir = config_dir();
    let identity = Identity::load_or_create(&dir)?;
    let mut trust = TrustStore::open(&dir)?;
    let self_info = self_info(flags.get("alias").cloned(), &identity, SERVICE_PORT);

    let target = resolve_target(to, &self_info).await?;

    // 송신 측 TOFU — 처음 보내는 기기면 1회 신뢰 확인 (4.4)
    if trust.contains(&target.info.fingerprint) == false {
        let ok = prompt_yn(&format!(
            "새 기기입니다. 신뢰할까요? ({}, 지문 {}…) [y/N] ",
            target.info.alias,
            &target.info.fingerprint[..16]
        ))
        .await;
        if ok == false {
            bail!("사용자가 신뢰를 거부했습니다");
        }
        trust.add(&target.info.fingerprint, &target.info.alias)?;
    }

    let mut files = HashMap::new();
    for (i, p) in paths.iter().enumerate() {
        let size = std::fs::metadata(p)?.len();
        files.insert(
            format!("f{}", i + 1),
            FileMeta {
                name: Path::new(p)
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| p.clone()),
                size,
                mime: mime_of(p),
            },
        );
    }

    let sender = Arc::new(Sender::new(&target.addr(), &target.info.fingerprint, self_info));
    println!("{}에게 전송 요청 — 수신자 승인 대기 중 (최대 60초)…", target.info.alias);
    let session = sender.prepare_upload(files.clone()).await?;

    // Ctrl+C 시 세션을 수신자에게 정리시킨다 (4.3 cancel)
    let cancel_sender = sender.clone();
    let cancel_session = session.session_id.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            cancel_sender.cancel(&cancel_session).await;
            eprintln!("\n취소됨");
            std::process::exit(1);
        }
    });

    for (i, p) in paths.iter().enumerate() {
        let file_id = format!("f{}", i + 1);
        let meta = &files[&file_id];
        let started = Instant::now();
        let uploaded = sender
            .upload_file(
                &session.session_id,
                &file_id,
                &session.tokens[&file_id],
                Path::new(p),
                meta.size,
            )
            .await;
        if let Err(e) = uploaded {
            sender.cancel(&session.session_id).await;
            bail!("{} 업로드 실패: {e:#}", meta.name);
        }
        let elapsed = started.elapsed().as_secs_f64().max(0.001);
        println!(
            "업로드 완료: {} ({}, {}/s)",
            meta.name,
            format_size(meta.size),
            format_size((meta.size as f64 / elapsed) as u64)
        );
    }
    Ok(())
}

// IP[:포트]면 /info 교환(폴백), 아니면 alias로 멀티캐스트 탐색
async fn resolve_target(to: &str, self_info: &PeerInfo) -> Result<Device> {
    let (host, port) = match to.rsplit_once(':') {
        Some((h, p)) => (h, p.parse().unwrap_or(SERVICE_PORT)),
        None => (to, SERVICE_PORT),
    };
    if let Ok(ip) = host.parse::<IpAddr>() {
        let addr = format!("{host}:{port}");
        let info = exchange_info(&addr, self_info)
            .await
            .with_context(|| format!("IP 직접 연결 실패 ({addr})"))?;
        return Ok(Device {
            info,
            ip,
            last_seen: Instant::now(),
        });
    }

    let d = Discoverer::start(self_info.clone()).await?;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(dev) = d.devices().into_iter().find(|dev| dev.info.alias == to) {
            return Ok(dev);
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    bail!("기기를 찾지 못했습니다: {to} (10초 탐색)");
}

async fn cmd_recv(args: &[String]) -> Result<()> {
    let (flags, _) = parse_args(args, &["dir", "alias"]);
    let save_dir = PathBuf::from(flags.get("dir").map_or(".", String::as_str));

    let dir = config_dir();
    let identity = Identity::load_or_create(&dir)?;
    let trust = TrustStore::open(&dir)?;
    let mut info = self_info(flags.get("alias").cloned(), &identity, 0);

    let receiver = Receiver::start(
        &identity,
        trust,
        &save_dir,
        info.clone(),
        Arc::new(|req: TransferRequest| {
            Box::pin(async move {
                let names: Vec<&str> = req.files.values().map(|f| f.name.as_str()).collect();
                let total: u64 = req.files.values().map(|f| f.size).sum();
                let badge = if req.is_new_device { " [새 기기]" } else { "" };
                prompt_yn(&format!(
                    "← {}{}가 {} ({}) 전송 요청 [y/N] ",
                    req.sender.alias,
                    badge,
                    names.join(", "),
                    format_size(total)
                ))
                .await
            })
        }),
        Some(Arc::new(|saved: SavedFile| {
            println!("저장 완료: {} (보낸 기기: {})", saved.path.display(), saved.from);
        })),
        None,
    )
    .await?;

    info.port = receiver.port();
    let _discoverer = Discoverer::start(info.clone()).await?;

    println!(
        "수신 대기 중 (alias: {}, 포트: {}, 저장: {}, 버전: {VERSION}) — Ctrl+C로 종료",
        info.alias,
        receiver.port(),
        save_dir.display()
    );
    tokio::signal::ctrl_c().await?;
    Ok(())
}

async fn prompt_yn(message: &str) -> bool {
    print!("{message}");
    let _ = std::io::stdout().flush();
    let answer = tokio::task::spawn_blocking(|| {
        let mut line = String::new();
        match std::io::stdin().read_line(&mut line) {
            Ok(_) => line,
            Err(_) => String::new(),
        }
    })
    .await
    .unwrap_or_default();
    matches!(answer.trim().to_lowercase().as_str(), "y" | "yes")
}

fn mime_of(path: &str) -> String {
    let ext = Path::new(path)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "pdf" => "application/pdf",
        "txt" | "md" => "text/plain",
        "json" => "application/json",
        "zip" => "application/zip",
        "mp4" => "video/mp4",
        _ => "application/octet-stream",
    }
    .to_string()
}

fn format_size(bytes: u64) -> String {
    const MB: f64 = 1024.0 * 1024.0;
    if bytes as f64 >= MB {
        format!("{:.1} MB", bytes as f64 / MB)
    } else {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    }
}
