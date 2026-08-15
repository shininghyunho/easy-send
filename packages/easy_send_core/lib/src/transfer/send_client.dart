import 'dart:convert';
import 'dart:io';

import '../models/device.dart';
import '../models/file_meta.dart';
import '../security/fingerprint.dart';

/// 수신 측 HTTP 에러 코드를 그대로 담는 예외 (PRD 4.3 에러 표).
class TransferException implements Exception {
  const TransferException(this.statusCode);

  final int statusCode;

  bool get declined => statusCode == HttpStatus.forbidden;
  bool get busy => statusCode == HttpStatus.conflict;
  bool get approvalTimedOut => statusCode == HttpStatus.requestTimeout;
  bool get invalidSession => statusCode == HttpStatus.notFound;

  @override
  String toString() => 'TransferException(HTTP $statusCode)';
}

/// TLS 인증서 지문이 탐색에서 광고된 지문과 다름 — 채널 무결성 위반 (PRD 4.4 검증 1단계).
class FingerprintMismatchException implements Exception {
  const FingerprintMismatchException(this.observed);

  final String observed;
}

class PreparedSession {
  const PreparedSession({required this.sessionId, required this.tokens});

  final String sessionId;
  final Map<String, String> tokens;
}

/// IP 직접 입력 폴백 — 기기 정보 교환 (PRD 4.2). 지문을 모른 채 접속하는
/// 유일한 경로라, 응답 바디의 fingerprint가 실제 제시된 인증서 지문과
/// 일치하는지로 채널을 검증한다.
Future<DiscoveredDevice> exchangeInfo({
  required String address,
  required int port,
  required DeviceInfo self,
}) async {
  final client = HttpClient();
  String? observed;
  client.badCertificateCallback = (cert, host, certPort) {
    observed = fingerprintOfDer(cert.der);
    return true;
  };
  try {
    final req = await client.postUrl(
        Uri(scheme: 'https', host: address, port: port, path: '/api/v1/info'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(self.toJson()));
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    if (res.statusCode != HttpStatus.ok) {
      throw TransferException(res.statusCode);
    }
    final info = DeviceInfo.tryFromJson(jsonDecode(body));
    if (info == null) {
      throw const TransferException(HttpStatus.internalServerError);
    }
    if (info.fingerprint != observed) {
      throw FingerprintMismatchException(observed ?? '');
    }
    return DiscoveredDevice(
      info: info,
      address: (await InternetAddress.lookup(address)).first,
      lastSeen: DateTime.now(),
    );
  } finally {
    client.close(force: true);
  }
}

/// 송신 측 HTTPS 클라이언트. 자체서명 인증서라 시스템 CA 검증 대신
/// "광고된 지문과 일치하는가"를 연결마다 확인한다.
class SendClient {
  SendClient({
    required this.address,
    required this.port,
    required this.expectedFingerprint,
  }) {
    _client.badCertificateCallback = (cert, host, certPort) {
      final observed = fingerprintOfDer(cert.der);
      if (observed == expectedFingerprint) return true;
      _mismatch = observed;
      return false;
    };
  }

  final String address;
  final int port;
  final String expectedFingerprint;

  final _client = HttpClient();
  String? _mismatch;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'https', host: address, port: port, path: path,
          queryParameters: query);

  /// IP 직접 입력 폴백 — 기기 정보 교환 (PRD 4.2).
  Future<DeviceInfo?> fetchInfo(DeviceInfo self) async {
    final res = await _postJson(_uri('/api/v1/info'), self.toJson());
    if (res.statusCode == HttpStatus.ok) {
      return DeviceInfo.tryFromJson(jsonDecode(await _readBody(res)));
    }
    throw TransferException(res.statusCode);
  }

  Future<PreparedSession> prepareUpload(
      DeviceInfo self, Map<String, FileMeta> files) async {
    final res = await _postJson(_uri('/api/v1/prepare-upload'), {
      'info': self.toJson(),
      'files': files.map((id, meta) => MapEntry(id, meta.toJson())),
    });
    if (res.statusCode == HttpStatus.ok) {
      final body = jsonDecode(await _readBody(res)) as Map<String, dynamic>;
      return PreparedSession(
        sessionId: body['sessionId'] as String,
        tokens: (body['tokens'] as Map<String, dynamic>).cast<String, String>(),
      );
    }
    await res.drain<void>();
    throw TransferException(res.statusCode);
  }

  Future<void> uploadFile(
    PreparedSession session,
    String fileId,
    File file, {
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    final total = file.lengthSync();
    final req = await _open('POST', _uri('/api/v1/upload', {
      'sessionId': session.sessionId,
      'fileId': fileId,
      'token': session.tokens[fileId]!,
    }));
    req.contentLength = total;
    var sent = 0;
    await req.addStream(file.openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent, total);
      return chunk;
    }));
    final res = await req.close();
    await res.drain<void>();
    if (res.statusCode == HttpStatus.ok) return;
    throw TransferException(res.statusCode);
  }

  Future<void> cancel(PreparedSession session) async {
    final res = await _postJson(
        _uri('/api/v1/cancel', {'sessionId': session.sessionId}), {});
    await res.drain<void>();
    if (res.statusCode == HttpStatus.ok) return;
    throw TransferException(res.statusCode);
  }

  void close() => _client.close(force: true);

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    try {
      return await _client.openUrl(method, uri);
    } on HandshakeException {
      final observed = _mismatch;
      if (observed != null) throw FingerprintMismatchException(observed);
      rethrow;
    }
  }

  Future<HttpClientResponse> _postJson(Uri uri, Map<String, dynamic> json) async {
    final req = await _open('POST', uri);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(json));
    return req.close();
  }

  Future<String> _readBody(HttpClientResponse res) =>
      utf8.decoder.bind(res).join();
}
