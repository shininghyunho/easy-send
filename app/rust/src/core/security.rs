// 4.4 보안 — 기기 ID = 자체서명 인증서 지문(SHA-256 hex), TOFU 신뢰 목록
use anyhow::{Context, Result};
use rustls::pki_types::CertificateDer;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

// 지문 = 인증서 DER 바이트의 SHA-256 (hex 64자리, 소문자)
pub fn fingerprint_of(der: &[u8]) -> String {
    hex::encode(Sha256::digest(der))
}

pub struct Identity {
    pub cert_der: Vec<u8>,
    key_pem: String,
    pub fingerprint: String,
}

impl Identity {
    // dir의 cert.pem/key.pem을 읽고, 없으면 생성해 저장한다
    pub fn load_or_create(dir: &Path) -> Result<Identity> {
        let cert_path = dir.join("cert.pem");
        let key_path = dir.join("key.pem");

        if cert_path.exists() {
            let cert_pem = fs::read(&cert_path).context("저장된 인증서 로드 실패")?;
            let key_pem = fs::read_to_string(&key_path).context("저장된 키 로드 실패")?;
            let cert_der = rustls_pemfile::certs(&mut cert_pem.as_slice())
                .next()
                .context("cert.pem에 인증서가 없습니다")??;
            return Ok(Identity {
                fingerprint: fingerprint_of(&cert_der),
                cert_der: cert_der.to_vec(),
                key_pem,
            });
        }

        fs::create_dir_all(dir)?;
        let key = rcgen::KeyPair::generate()?;
        let mut params = rcgen::CertificateParams::default();
        params.distinguished_name = rcgen::DistinguishedName::new();
        params
            .distinguished_name
            .push(rcgen::DnType::CommonName, "easy-send");
        let cert = params.self_signed(&key)?;
        fs::write(&cert_path, cert.pem())?;
        fs::write(&key_path, key.serialize_pem())?;
        Ok(Identity {
            fingerprint: fingerprint_of(cert.der()),
            cert_der: cert.der().to_vec(),
            key_pem: key.serialize_pem(),
        })
    }

    pub fn server_config(&self) -> Result<rustls::ServerConfig> {
        let key = rustls_pemfile::private_key(&mut self.key_pem.as_bytes())?
            .context("key.pem에 키가 없습니다")?;
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![CertificateDer::from(self.cert_der.clone())], key)?;
        Ok(config)
    }
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct TrustedDevice {
    pub alias: String,
    pub trusted_at: String,
}

// (지문, alias, 최초 승인 시각)을 로컬 JSON에 저장
pub struct TrustStore {
    path: PathBuf,
    devices: HashMap<String, TrustedDevice>,
}

impl TrustStore {
    pub fn open(dir: &Path) -> Result<TrustStore> {
        let path = dir.join("trusted.json");
        let devices = match fs::read(&path) {
            // 파싱 불가(Dart 시절 배열 포맷 등)면 빈 스토어로 시작 — TOFU 재승인으로 복구된다
            Ok(data) => serde_json::from_slice(&data).unwrap_or_default(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(e) => return Err(e.into()),
        };
        Ok(TrustStore { path, devices })
    }

    pub fn contains(&self, fingerprint: &str) -> bool {
        self.devices.contains_key(fingerprint)
    }

    // trustedAt은 최초 승인 시각이므로 이미 아는 기기는 덮어쓰지 않는다 (4.4)
    pub fn add(&mut self, fingerprint: &str, alias: &str) -> Result<()> {
        if self.contains(fingerprint) {
            return Ok(());
        }
        self.devices.insert(
            fingerprint.to_string(),
            TrustedDevice {
                alias: alias.to_string(),
                trusted_at: OffsetDateTime::now_utc().format(&Rfc3339)?,
            },
        );
        self.save()
    }

    pub fn remove(&mut self, fingerprint: &str) -> Result<()> {
        if self.devices.remove(fingerprint).is_none() {
            return Ok(());
        }
        self.save()
    }

    pub fn all(&self) -> Vec<(String, TrustedDevice)> {
        let mut list: Vec<(String, TrustedDevice)> = self
            .devices
            .iter()
            .map(|(fp, dev)| (fp.clone(), dev.clone()))
            .collect();
        list.sort_by(|a, b| a.1.trusted_at.cmp(&b.1.trusted_at));
        list
    }

    fn save(&self) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&self.path, serde_json::to_vec_pretty(&self.devices)?)?;
        Ok(())
    }
}
