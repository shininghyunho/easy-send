import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'rust/api/easy_send.dart';

/// MulticastLock(S2)·MediaStore 저장(S3) — Android 전용 네이티브 채널.
const _native = MethodChannel('easy_send/native');

/// MediaStore가 Download/에 쓴 파일의 실제 공개 경로 (표시용).
const _androidDownloadsPath = '/storage/emulated/0/Download';

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

/// Rust 노드(신원·신뢰 목록·수신 서버·탐색)의 생명주기 소유자.
/// 설정 변경은 노드 재시작으로 반영한다.
class AppController extends ChangeNotifier {
  AppController._(this._baseDir, this._settings);

  final Directory _baseDir;
  AppSettings _settings;

  NodeStatus? _node;
  StreamSubscription<List<DeviceSnapshot>>? _deviceSub;
  StreamSubscription<SavedFileEvent>? _savedSub;
  // 설정 변경으로 노드가 재시작돼도 UI 구독은 이 스트림 하나로 유지
  final _devicesOut = StreamController<List<DeviceSnapshot>>.broadcast();
  List<DeviceSnapshot> _currentDevices = const [];

  /// IP 직접 입력으로 추가한 기기 — 탐색과 달리 TTL 없이 유지 (PRD 4.2 폴백).
  final manualDevices = <DeviceSnapshot>[];

  /// 이번 실행에서 받은 파일 (최신순, 영속 없음 — R5 히스토리 비목표).
  final recentReceived = <File>[];

  /// 신뢰 기기 캐시 — 시작·승인·추가·해제 시 Rust에서 다시 읽는다.
  List<TrustedDeviceView> trusted = const [];

  /// 수신 승인 다이얼로그. UI 계층이 앱 시작 시 연결한다.
  Future<bool> Function(ApprovalRequest request)? approvalHandler;

  AppSettings get settings => _settings;
  int get port => _node?.port ?? 0;
  String get fingerprint => _node?.fingerprint ?? '';
  Stream<List<DeviceSnapshot>> get devices => _devicesOut.stream;
  List<DeviceSnapshot> get currentDevices => _currentDevices;

  static Future<AppController> start() async {
    if (Platform.isAndroid) {
      await _native.invokeMethod('acquireMulticastLock');
    }
    final baseDir = await getApplicationSupportDirectory();
    final settings = await _loadSettings(baseDir);
    final controller = AppController._(baseDir, settings);
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
    // Android는 saveDir가 MediaStore로 옮기기 전 대기 폴더 (S3 — 직접 쓰기 불가)
    if (Platform.isAndroid) {
      return AppSettings(alias: 'Android', saveDirPath: '${baseDir.path}/inbox');
    }
    final downloads = await getDownloadsDirectory();
    return AppSettings(
      alias: Platform.localHostname,
      saveDirPath: (downloads ?? baseDir).path,
    );
  }

  Future<void> _startServices() async {
    _node = await nodeStart(
      config: NodeConfig(
        baseDir: _baseDir.path,
        saveDir: _settings.saveDirPath,
        alias: _settings.alias,
        deviceType: Platform.isAndroid ? 'mobile' : 'desktop',
      ),
      onApproval: _onApproval,
    );
    _deviceSub = nodeDeviceEvents().listen((list) {
      _currentDevices = list;
      _devicesOut.add(list);
    });
    _savedSub = nodeSavedEvents().listen(_onSaved);
    await _refreshTrusted();
    notifyListeners();
  }

  Future<bool> _onApproval(ApprovalRequest request) async {
    final approved = await approvalHandler?.call(request) ?? false;
    // 승인 시 Rust가 TOFU 기록을 남기므로 캐시를 따라간다
    if (approved) unawaited(_refreshTrusted());
    return approved;
  }

  void _onSaved(SavedFileEvent event) {
    if (Platform.isAndroid) {
      _exportToDownloads(File(event.path));
      return;
    }
    _recordReceived(File(event.path));
  }

  void _recordReceived(File file) {
    recentReceived.insert(0, file);
    if (recentReceived.length > 20) recentReceived.removeLast();
    notifyListeners();
  }

  Future<void> _exportToDownloads(File saved) async {
    try {
      final name = await _native
          .invokeMethod<String>('saveToDownloads', {'path': saved.path});
      _recordReceived(
          File('$_androidDownloadsPath/${name ?? saved.uri.pathSegments.last}'));
    } catch (_) {
      // MediaStore 이동 실패 시 대기 폴더 원본 위치로 표시
      _recordReceived(saved);
    }
  }

  Future<void> _refreshTrusted() async {
    trusted = await trustList();
    notifyListeners();
  }

  Future<void> _stopServices() async {
    await _deviceSub?.cancel();
    await _savedSub?.cancel();
    _deviceSub = null;
    _savedSub = null;
    await nodeStop();
  }

  Future<void> applySettings(AppSettings next) async {
    _settings = next;
    File('${_baseDir.path}/settings.json')
        .writeAsStringSync(jsonEncode(next.toJson()));
    await _stopServices();
    await _startServices();
  }

  /// UI 새로고침 버튼 = 즉시 announce 1회 (PRD 4.2).
  void refreshDiscovery() => unawaited(nodeAnnounce());

  void addManualDevice(DeviceSnapshot device) {
    if (device.fingerprint == fingerprint) return;
    manualDevices.removeWhere((d) => d.fingerprint == device.fingerprint);
    manualDevices.add(device);
    notifyListeners();
  }

  Future<bool> isTrusted(String fingerprint) =>
      trustContains(fingerprint: fingerprint);

  Future<void> addTrusted(String fingerprint, String alias) async {
    await trustAdd(fingerprint: fingerprint, alias: alias);
    await _refreshTrusted();
  }

  Future<void> removeTrusted(String fingerprint) async {
    await trustRemove(fingerprint: fingerprint);
    await _refreshTrusted();
  }
}
