// 전송 프로토콜 검증 (PRD 4.3·4.4). 2프로세스 프로브는 happy path만 관찰
// 가능하므로, 에러 경로와 상태머신·TOFU 규칙은 여기서 고정한다.
import 'dart:async';
import 'dart:io';

import 'package:easy_send_core/easy_send_core.dart';
import 'package:test/test.dart';

void main() {
  late DeviceIdentity identity;
  late Directory tempDir;

  setUpAll(() {
    identity = DeviceIdentity.generate();
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('easy_send_test');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  DeviceInfo senderInfo({String? fingerprint}) => DeviceInfo(
        alias: 'sender',
        deviceType: DeviceType.desktop,
        fingerprint: fingerprint ?? 'f' * 64,
        port: 1,
      );

  Future<ReceiveServer> startServer({
    required Future<bool> Function(TransferRequest) onApproval,
    Duration approvalTimeout = const Duration(seconds: 60),
    TrustStore? trustStore,
  }) async {
    final server = ReceiveServer(
      identity: identity,
      self: DeviceInfo(
        alias: 'receiver',
        deviceType: DeviceType.desktop,
        fingerprint: identity.fingerprint,
        port: 0,
      ),
      trustStore: trustStore ?? TrustStore(File('${tempDir.path}/trust.json')),
      saveDir: tempDir,
      onApprovalRequest: onApproval,
      approvalTimeout: approvalTimeout,
    );
    await server.start();
    return server;
  }

  SendClient clientFor(ReceiveServer server, {String? fingerprint}) =>
      SendClient(
        address: '127.0.0.1',
        port: server.port,
        expectedFingerprint: fingerprint ?? identity.fingerprint,
      );

  File writeSource(String name, String content) =>
      File('${tempDir.path}/src_$name')..writeAsStringSync(content);

  Map<String, FileMeta> metaOf(Map<String, File> files) => files.map(
      (id, f) => MapEntry(id,
          FileMeta(name: f.path.split('src_').last, size: f.lengthSync(), mime: 'text/plain')));

  test('승인 → 2파일 순차 업로드 → 내용 일치, TOFU 등록, 재전송은 충돌 회피 이름', () async {
    final trust = TrustStore(File('${tempDir.path}/trust.json'));
    final seenIsNew = <bool>[];
    final server = await startServer(
      trustStore: trust,
      onApproval: (req) async {
        seenIsNew.add(req.isNewDevice);
        return true;
      },
    );
    final client = clientFor(server);
    final files = {
      'f1': writeSource('a.txt', 'hello'),
      'f2': writeSource('b.txt', 'world!'),
    };

    for (var round = 0; round < 2; round++) {
      final session = await client.prepareUpload(senderInfo(), metaOf(files));
      for (final entry in files.entries) {
        await client.uploadFile(session, entry.key, entry.value);
      }
    }

    expect(File('${tempDir.path}/a.txt').readAsStringSync(), 'hello');
    expect(File('${tempDir.path}/a (1).txt').readAsStringSync(), 'hello');
    expect(File('${tempDir.path}/b (1).txt').readAsStringSync(), 'world!');
    expect(seenIsNew, [true, false], reason: '승인 후 TOFU 등록 → 2회차는 알던 기기');
    expect(trust.contains('f' * 64), isTrue);
    expect(server.state, ReceiveState.idle, reason: '전 파일 완료 = 세션 종료');
    client.close();
    await server.stop();
  });

  test('거절 → 403', () async {
    final server = await startServer(onApproval: (_) async => false);
    final client = clientFor(server);
    await expectLater(
      client.prepareUpload(senderInfo(), metaOf({'f1': writeSource('a.txt', 'x')})),
      throwsA(predicate((e) => e is TransferException && e.declined)),
    );
    expect(server.state, ReceiveState.idle);
    client.close();
    await server.stop();
  });

  test('pending 중 새 prepare-upload → 409 busy', () async {
    final server = await startServer(
      onApproval: (_) => Future.delayed(const Duration(seconds: 1), () => true),
    );
    final client = clientFor(server);
    final meta = metaOf({'f1': writeSource('a.txt', 'x')});
    final first = client.prepareUpload(senderInfo(), meta);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await expectLater(
      clientFor(server).prepareUpload(senderInfo(fingerprint: 'e' * 64), meta),
      throwsA(predicate((e) => e is TransferException && e.busy)),
    );
    await first;
    client.close();
    await server.stop();
  });

  test('승인 무응답 → 408, 세션은 idle 복귀', () async {
    final server = await startServer(
      approvalTimeout: const Duration(milliseconds: 200),
      onApproval: (_) => Completer<bool>().future,
    );
    final client = clientFor(server);
    await expectLater(
      client.prepareUpload(senderInfo(), metaOf({'f1': writeSource('a.txt', 'x')})),
      throwsA(predicate((e) => e is TransferException && e.approvalTimedOut)),
    );
    expect(server.state, ReceiveState.idle);
    client.close();
    await server.stop();
  });

  test('송신 취소 후 upload → 404', () async {
    final server = await startServer(onApproval: (_) async => true);
    final client = clientFor(server);
    final file = writeSource('a.txt', 'x');
    final session = await client.prepareUpload(senderInfo(), metaOf({'f1': file}));
    await client.cancel(session);
    await expectLater(
      client.uploadFile(session, 'f1', file),
      throwsA(predicate((e) => e is TransferException && e.invalidSession)),
    );
    client.close();
    await server.stop();
  });

  test('수신 측 취소 후 upload → 404', () async {
    final server = await startServer(onApproval: (_) async => true);
    final client = clientFor(server);
    final file = writeSource('a.txt', 'x');
    final session = await client.prepareUpload(senderInfo(), metaOf({'f1': file}));
    server.cancelActiveSession();
    await expectLater(
      client.uploadFile(session, 'f1', file),
      throwsA(predicate((e) => e is TransferException && e.invalidSession)),
    );
    client.close();
    await server.stop();
  });

  test('틀린 token → 404', () async {
    final server = await startServer(onApproval: (_) async => true);
    final client = clientFor(server);
    final file = writeSource('a.txt', 'x');
    final session = await client.prepareUpload(senderInfo(), metaOf({'f1': file}));
    final forged = PreparedSession(
        sessionId: session.sessionId, tokens: {'f1': 'deadbeef'});
    await expectLater(
      client.uploadFile(forged, 'f1', file),
      throwsA(predicate((e) => e is TransferException && e.invalidSession)),
    );
    client.close();
    await server.stop();
  });

  test('광고 지문과 인증서 불일치 → 연결 자체가 거부된다 (채널 무결성)', () async {
    final server = await startServer(onApproval: (_) async => true);
    final client = clientFor(server, fingerprint: '0' * 64);
    await expectLater(
      client.prepareUpload(senderInfo(), metaOf({'f1': writeSource('a.txt', 'x')})),
      throwsA(isA<FingerprintMismatchException>()),
    );
    client.close();
    await server.stop();
  });
}
