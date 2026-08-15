import 'dart:convert';
import 'dart:io';

/// TOFU 신뢰 목록의 항목 1개 (PRD 4.4).
class TrustedDevice {
  const TrustedDevice({
    required this.fingerprint,
    required this.alias,
    required this.firstApprovedAt,
  });

  final String fingerprint;
  final String alias;
  final DateTime firstApprovedAt;

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'alias': alias,
        'firstApprovedAt': firstApprovedAt.toIso8601String(),
      };

  static TrustedDevice fromJson(Map<String, dynamic> json) => TrustedDevice(
        fingerprint: json['fingerprint'] as String,
        alias: json['alias'] as String,
        firstApprovedAt: DateTime.parse(json['firstApprovedAt'] as String),
      );
}

/// TOFU 신뢰 목록 — JSON 파일 1개로 영속. 수신 승인·송신 최초 신뢰 시 추가된다.
class TrustStore {
  TrustStore(this._file) {
    if (_file.existsSync()) {
      final list = jsonDecode(_file.readAsStringSync()) as List<dynamic>;
      for (final e in list) {
        final device = TrustedDevice.fromJson(e as Map<String, dynamic>);
        _devices[device.fingerprint] = device;
      }
    }
  }

  final File _file;
  final _devices = <String, TrustedDevice>{};

  bool contains(String fingerprint) => _devices.containsKey(fingerprint);

  List<TrustedDevice> get all => List.unmodifiable(_devices.values);

  Future<void> add(String fingerprint, String alias) async {
    if (contains(fingerprint)) return;
    _devices[fingerprint] = TrustedDevice(
      fingerprint: fingerprint,
      alias: alias,
      firstApprovedAt: DateTime.now(),
    );
    await _save();
  }

  Future<void> remove(String fingerprint) async {
    _devices.remove(fingerprint);
    await _save();
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
        jsonEncode(_devices.values.map((d) => d.toJson()).toList()));
  }
}
