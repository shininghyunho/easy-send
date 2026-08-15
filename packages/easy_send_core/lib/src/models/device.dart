import 'dart:convert';
import 'dart:io';

import '../protocol.dart';

enum DeviceType {
  mobile,
  desktop;

  static DeviceType fromName(String name) =>
      DeviceType.values.firstWhere((t) => t.name == name,
          orElse: () => DeviceType.desktop);
}

/// 내 기기가 광고하는 정보 — announce 메시지의 기기 부분 (PRD 4.2).
class DeviceInfo {
  const DeviceInfo({
    required this.alias,
    required this.deviceType,
    required this.fingerprint,
    required this.port,
  });

  final String alias;
  final DeviceType deviceType;

  /// 기기 ID = SHA-256(인증서 DER) 64자리 hex (PRD 4.4).
  final String fingerprint;

  /// 이 기기의 HTTPS 서버 포트.
  final int port;

  Map<String, dynamic> toJson() => {
        'alias': alias,
        'deviceType': deviceType.name,
        'fingerprint': fingerprint,
        'port': port,
      };

  static DeviceInfo? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final alias = json['alias'];
    final deviceType = json['deviceType'];
    final fingerprint = json['fingerprint'];
    final port = json['port'];
    if (alias is! String ||
        deviceType is! String ||
        fingerprint is! String ||
        port is! int) {
      return null;
    }
    return DeviceInfo(
      alias: alias,
      deviceType: DeviceType.fromName(deviceType),
      fingerprint: fingerprint,
      port: port,
    );
  }
}

/// 탐색 UDP 패킷 1개 — announce(멀티캐스트) 또는 그 응답(유니캐스트).
class Announcement {
  const Announcement({required this.info, required this.announce});

  final DeviceInfo info;

  /// true=최초 알림(응답 필요), false=응답.
  final bool announce;

  List<int> encode() => utf8.encode(jsonEncode({
        'app': Protocol.app,
        'version': Protocol.version,
        ...info.toJson(),
        'protocol': Protocol.scheme,
        'announce': announce,
      }));

  /// 유효한 easy-send 패킷이 아니면 null.
  /// 무시 규칙(PRD 4.2): app 불일치, version 메이저 불일치.
  static Announcement? tryDecode(List<int> bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['app'] != Protocol.app) return null;
    final version = decoded['version'];
    if (version is! String ||
        version.split('.').first != Protocol.versionMajor) {
      return null;
    }
    final info = DeviceInfo.tryFromJson(decoded);
    final announce = decoded['announce'];
    if (info == null || announce is! bool) return null;
    return Announcement(info: info, announce: announce);
  }
}

/// 탐색으로 발견된 상대 기기 — 기기 목록의 항목 1개.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.info,
    required this.address,
    required this.lastSeen,
  });

  final DeviceInfo info;
  final InternetAddress address;
  final DateTime lastSeen;

  @override
  String toString() =>
      '${info.alias}(${info.deviceType.name})@${address.address}:${info.port}';
}
