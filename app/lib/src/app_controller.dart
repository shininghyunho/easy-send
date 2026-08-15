import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_send_core/easy_send_core.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 앱 전역 설정 — baseDir/settings.json 1파일로 영속.
class AppSettings {
  const AppSettings({required this.alias, required this.saveDirPath});

  final String alias;
  final String saveDirPath;

  AppSettings copyWith({String? alias, String? saveDirPath}) => AppSettings(
        alias: alias ?? this.alias,
        saveDirPath: saveDirPath ?? this.saveDirPath,
      );

  Map<String, dynamic> toJson() => {'alias': alias, 'saveDirPath': saveDirPath};
}

/// core 서비스(신원·신뢰 목록·수신 서버·탐색)의 생명주기 소유자.
/// 설정 변경은 서비스 재시작으로 반영한다.
class AppController extends ChangeNotifier {
  AppController._(this._baseDir, this.identity, this.trustStore, this._settings);

  final Directory _baseDir;
  final DeviceIdentity identity;
  final TrustStore trustStore;
  AppSettings _settings;

  ReceiveServer? _server;
  DiscoveryService? _discovery;
  StreamSubscription<List<DiscoveredDevice>>? _deviceSub;
  // 설정 변경으로 DiscoveryService가 교체돼도 UI 구독은 이 스트림 하나로 유지
  final _devicesOut = StreamController<List<DiscoveredDevice>>.broadcast();

  /// IP 직접 입력으로 추가한 기기 — 탐색과 달리 TTL 없이 유지 (PRD 4.2 폴백).
  final manualDevices = <DiscoveredDevice>[];

  /// 이번 실행에서 받은 파일 (최신순, 영속 없음 — R5 히스토리 비목표).
  final recentReceived = <File>[];

  /// 수신 승인 다이얼로그. UI 계층이 앱 시작 시 연결한다.
  Future<bool> Function(TransferRequest request)? approvalHandler;

  AppSettings get settings => _settings;
  int get port => _server?.port ?? 0;
  Stream<List<DiscoveredDevice>> get devices => _devicesOut.stream;
  List<DiscoveredDevice> get currentDevices =>
      _discovery?.currentDevices ?? const [];

  DeviceInfo get self => DeviceInfo(
        alias: _settings.alias,
        deviceType: Platform.isAndroid ? DeviceType.mobile : DeviceType.desktop,
        fingerprint: identity.fingerprint,
        port: port,
      );

  static Future<AppController> start() async {
    final baseDir = await getApplicationSupportDirectory();
    final identity = await DeviceIdentity.loadOrCreate(baseDir);
    final trustStore = TrustStore(File('${baseDir.path}/trusted.json'));
    final settings = await _loadSettings(baseDir);
    final controller = AppController._(baseDir, identity, trustStore, settings);
    await controller._startServices();
    return controller;
  }

  static Future<AppSettings> _loadSettings(Directory baseDir) async {
    final file = File('${baseDir.path}/settings.json');
    if (file.existsSync()) {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return AppSettings(
        alias: json['alias'] as String,
        saveDirPath: json['saveDirPath'] as String,
      );
    }
    final downloads = await getDownloadsDirectory();
    return AppSettings(
      alias: Platform.localHostname,
      saveDirPath: (downloads ?? baseDir).path,
    );
  }

  Future<void> _startServices() async {
    final saveDir = Directory(_settings.saveDirPath)
      ..createSync(recursive: true);
    final server = ReceiveServer(
      identity: identity,
      self: DeviceInfo(
        alias: _settings.alias,
        deviceType:
            Platform.isAndroid ? DeviceType.mobile : DeviceType.desktop,
        fingerprint: identity.fingerprint,
        port: 0,
      ),
      trustStore: trustStore,
      saveDir: saveDir,
      onApprovalRequest: (req) => approvalHandler?.call(req) ?? Future.value(false),
      onFileSaved: (fileId, saved) {
        recentReceived.insert(0, saved);
        if (recentReceived.length > 20) recentReceived.removeLast();
        notifyListeners();
      },
    );
    // PRD 4.1: 기본 포트가 사용 중이면 임의 포트로 열고 announce의 port로 알린다
    try {
      await server.start(port: Protocol.defaultServicePort);
    } on SocketException {
      await server.start();
    }
    _server = server;

    final discovery = DiscoveryService(self: self);
    await discovery.start();
    _deviceSub = discovery.devices.listen(_devicesOut.add);
    _discovery = discovery;
    notifyListeners();
  }

  Future<void> _stopServices() async {
    await _deviceSub?.cancel();
    _discovery?.stop();
    await _server?.stop();
    _deviceSub = null;
    _discovery = null;
    _server = null;
  }

  Future<void> applySettings(AppSettings next) async {
    _settings = next;
    File('${_baseDir.path}/settings.json')
        .writeAsStringSync(jsonEncode(next.toJson()));
    await _stopServices();
    await _startServices();
  }

  /// UI 새로고침 버튼 = 즉시 announce 1회 (PRD 4.2).
  void refreshDiscovery() => _discovery?.announce();

  void addManualDevice(DiscoveredDevice device) {
    if (device.info.fingerprint == identity.fingerprint) return;
    manualDevices
        .removeWhere((d) => d.info.fingerprint == device.info.fingerprint);
    manualDevices.add(device);
    notifyListeners();
  }

  Future<void> removeTrusted(String fingerprint) async {
    await trustStore.remove(fingerprint);
    notifyListeners();
  }
}
