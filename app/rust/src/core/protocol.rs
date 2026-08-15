// PRD 4장 프로토콜 스펙 v1의 공통 상수·스키마 (Dart core·Go CLI와 와이어 호환이 계약)
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::time::Duration;

pub const APP: &str = "easy-send";
pub const VERSION: &str = "1.0";
pub const MULTICAST_GROUP: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 168);
pub const DISCOVERY_PORT: u16 = 53318;
pub const SERVICE_PORT: u16 = 53318;
pub const API_PREFIX: &str = "/api/v1";
pub const ANNOUNCE_INTERVAL: Duration = Duration::from_secs(5);
pub const DEVICE_TTL: Duration = Duration::from_secs(15);
pub const APPROVAL_TIMEOUT: Duration = Duration::from_secs(60);

// announce 스키마의 기기 부분 (4.2). Dart 피어는 /info·prepare-upload의 info에
// 이 4필드만 보내므로 app/version/protocol은 여기 두지 않는다.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PeerInfo {
    pub alias: String,
    pub device_type: String,
    pub fingerprint: String,
    pub port: u16,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Announcement {
    pub app: String,
    pub version: String,
    #[serde(flatten)]
    pub info: PeerInfo,
    #[serde(default = "default_scheme")]
    pub protocol: String,
    pub announce: bool,
}

fn default_scheme() -> String {
    "https".to_string()
}

impl Announcement {
    pub fn new(info: PeerInfo, announce: bool) -> Self {
        Self {
            app: APP.to_string(),
            version: VERSION.to_string(),
            info,
            protocol: default_scheme(),
            announce,
        }
    }

    // 다른 앱이거나 메이저 버전이 다르면 무시한다 (4.2 필드 규칙)
    pub fn compatible(&self) -> bool {
        self.app == APP && major_of(&self.version) == major_of(VERSION)
    }

    pub fn decode(data: &[u8]) -> Option<Announcement> {
        let ann: Announcement = serde_json::from_slice(data).ok()?;
        if ann.compatible() {
            Some(ann)
        } else {
            None
        }
    }
}

fn major_of(version: &str) -> &str {
    version.split('.').next().unwrap_or(version)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FileMeta {
    pub name: String,
    pub size: u64,
    pub mime: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PrepareUploadRequest {
    pub info: PeerInfo,
    pub files: HashMap<String, FileMeta>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadResponse {
    pub session_id: String,
    pub tokens: HashMap<String, String>,
}
