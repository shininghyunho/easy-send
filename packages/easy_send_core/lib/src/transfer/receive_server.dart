import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/device.dart';
import '../models/file_meta.dart';
import '../security/device_identity.dart';
import '../security/trust_store.dart';

/// 수신 승인 다이얼로그에 보여줄 요청 내용.
class TransferRequest {
  const TransferRequest({
    required this.sender,
    required this.files,
    required this.isNewDevice,
  });

  final DeviceInfo sender;
  final Map<String, FileMeta> files;

  /// TOFU 신뢰 목록에 없는 지문이면 true → UI에 "새 기기" 뱃지 (PRD 4.4).
  final bool isNewDevice;
}

enum ReceiveState { idle, pending, sending }

/// 수신 측 HTTPS 서버 — 세션 상태머신(idle→pending→sending, 동시 1세션)과
/// /api/v1/{info,prepare-upload,upload,cancel} 구현 (PRD 4.3).
class ReceiveServer {
  ReceiveServer({
    required this.identity,
    required this.self,
    required this.trustStore,
    required this.saveDir,
    required this.onApprovalRequest,
    this.onFileSaved,
    this.onSessionDone,
    this.approvalTimeout = const Duration(seconds: 60),
  });

  final DeviceIdentity identity;
  final DeviceInfo self;
  final TrustStore trustStore;
  final Directory saveDir;

  /// 승인 다이얼로그. true=승인, false=거절. [approvalTimeout] 초과 시 408.
  final Future<bool> Function(TransferRequest request) onApprovalRequest;
  final void Function(String fileId, File saved)? onFileSaved;
  final void Function()? onSessionDone;
  final Duration approvalTimeout;

  HttpServer? _server;
  ReceiveState _state = ReceiveState.idle;
  _Session? _session;
  final _random = Random.secure();

  ReceiveState get state => _state;
  int get port => _server!.port;

  Future<void> start({int port = 0}) async {
    final server = await HttpServer.bindSecure(
        InternetAddress.anyIPv4, port, identity.serverContext());
    server.listen(_route, onError: (_) {});
    _server = server;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// 수신 측 취소 — 세션 무효화, 이후 upload는 404 (PRD 4.3).
  void cancelActiveSession() => _endSession();

  Future<void> _route(HttpRequest req) async {
    try {
      if (req.method == 'POST' && req.uri.path == '/api/v1/info') {
        await _handleInfo(req);
      } else if (req.method == 'POST' &&
          req.uri.path == '/api/v1/prepare-upload') {
        await _handlePrepareUpload(req);
      } else if (req.method == 'POST' && req.uri.path == '/api/v1/upload') {
        await _handleUpload(req);
      } else if (req.method == 'POST' && req.uri.path == '/api/v1/cancel') {
        await _handleCancel(req);
      } else {
        await _respond(req, HttpStatus.notFound);
      }
    } catch (_) {
      await _respond(req, HttpStatus.internalServerError);
    }
  }

  Future<void> _handleInfo(HttpRequest req) async {
    await utf8.decoder.bind(req).join();
    // self.port는 바인딩 전 값(0)일 수 있어 실제 포트로 바꿔 응답한다
    await _respondJson(req, {...self.toJson(), 'port': port});
  }

  Future<void> _handlePrepareUpload(HttpRequest req) async {
    final body = await _readJson(req);
    final sender = DeviceInfo.tryFromJson(body?['info']);
    final filesJson = body?['files'];
    if (sender == null || filesJson is! Map<String, dynamic>) {
      await _respond(req, HttpStatus.badRequest);
      return;
    }
    final files = <String, FileMeta>{};
    for (final entry in filesJson.entries) {
      final meta = FileMeta.tryFromJson(entry.value);
      if (meta == null) {
        await _respond(req, HttpStatus.badRequest);
        return;
      }
      files[entry.key] = meta;
    }
    if (files.isEmpty) {
      await _respond(req, HttpStatus.badRequest);
      return;
    }

    if (_state == ReceiveState.idle) {
      _state = ReceiveState.pending;
    } else {
      await _respond(req, HttpStatus.conflict);
      return;
    }

    final request = TransferRequest(
      sender: sender,
      files: files,
      isNewDevice: trustStore.contains(sender.fingerprint) == false,
    );
    final bool approved;
    try {
      approved = await onApprovalRequest(request).timeout(approvalTimeout);
    } on TimeoutException {
      _state = ReceiveState.idle;
      await _respond(req, HttpStatus.requestTimeout);
      return;
    }
    if (approved == false) {
      _state = ReceiveState.idle;
      await _respond(req, HttpStatus.forbidden);
      return;
    }

    await trustStore.add(sender.fingerprint, sender.alias);
    final session = _Session(
      id: _token(),
      files: files,
      tokens: {for (final id in files.keys) id: _token()},
    );
    _session = session;
    _state = ReceiveState.sending;
    await _respondJson(req, {'sessionId': session.id, 'tokens': session.tokens});
  }

  Future<void> _handleUpload(HttpRequest req) async {
    final sessionId = req.uri.queryParameters['sessionId'];
    final fileId = req.uri.queryParameters['fileId'];
    final token = req.uri.queryParameters['token'];
    final session = _session;
    final validRequest = _state == ReceiveState.sending &&
        session != null &&
        session.id == sessionId &&
        fileId != null &&
        session.tokens[fileId] == token &&
        session.received.contains(fileId) == false;
    if (validRequest == false) {
      await req.drain<void>();
      await _respond(req, HttpStatus.notFound);
      return;
    }

    final meta = session!.files[fileId]!;
    final target = _resolveCollision(meta.name);
    final sink = target.openWrite();
    var written = 0;
    try {
      await for (final chunk in req) {
        written += chunk.length;
        sink.add(chunk);
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      target.deleteSync();
      _endSession();
      await _respond(req, HttpStatus.internalServerError);
      return;
    }
    // 크기 불일치 = 손상된 파일을 조용히 남기지 않고 즉시 실패시킨다
    if (written != meta.size) {
      target.deleteSync();
      _endSession();
      await _respond(req, HttpStatus.internalServerError);
      return;
    }

    session.received.add(fileId!);
    onFileSaved?.call(fileId, target);
    await _respond(req, HttpStatus.ok);
    if (session.received.length == session.files.length) {
      _endSession();
      onSessionDone?.call();
    }
  }

  Future<void> _handleCancel(HttpRequest req) async {
    await req.drain<void>();
    final session = _session;
    if (session != null && session.id == req.uri.queryParameters['sessionId']) {
      _endSession();
      await _respond(req, HttpStatus.ok);
    } else {
      await _respond(req, HttpStatus.notFound);
    }
  }

  void _endSession() {
    _session = null;
    _state = ReceiveState.idle;
  }

  /// 파일명 충돌 시 `name (1).ext` 식 번호 부여 — 덮어쓰기 금지 (PRD 4.3).
  File _resolveCollision(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var candidate = File('${saveDir.path}/$name');
    var n = 1;
    while (candidate.existsSync()) {
      candidate = File('${saveDir.path}/$base ($n)$ext');
      n++;
    }
    return candidate;
  }

  String _token() =>
      List.generate(32, (_) => _random.nextInt(16).toRadixString(16)).join();

  Future<Map<String, dynamic>?> _readJson(HttpRequest req) async {
    try {
      final decoded = jsonDecode(await utf8.decoder.bind(req).join());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _respond(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }

  Future<void> _respondJson(HttpRequest req, Map<String, dynamic> json) async {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(json));
    await req.response.close();
  }
}

class _Session {
  _Session({required this.id, required this.files, required this.tokens});

  final String id;
  final Map<String, FileMeta> files;
  final Map<String, String> tokens;
  final received = <String>{};
}
