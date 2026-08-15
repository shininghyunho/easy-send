// P3-2 FRB 경계 검증 — Rust 유닛 테스트는 core만 다루고, 승인 콜백(Dart 클로저를
// Rust 서버가 await)·이벤트 스트림·생성 타입 변환은 실제 브리지 위에서만 검증
// 가능하다. Rust CLI(easy-send-rs)를 별도 프로세스 피어로 두고 UI 없이 실증한다.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:easy_send_app/src/rust/api/easy_send.dart';
import 'package:easy_send_app/src/rust/frb_generated.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 실행 중 앱의 cwd는 프로젝트 폴더가 아니라 --dart-define으로 주입한다
  const cliBinary = String.fromEnvironment('EASY_SEND_RS');
  late Directory baseDir;
  late Directory saveDir;
  late Directory peerHome;
  late NodeStatus node;
  Future<bool> Function(ApprovalRequest) onApproval = (_) async => true;
  ApprovalRequest? lastRequest;
  // FRB 스트림은 suite 전체에서 1회 구독 유지 — 테스트 중 cancel은
  // Rust 쪽 다음 이벤트까지 완료되지 않을 수 있어 피한다
  final savedEvents = <SavedFileEvent>[];

  Uint8List payloadOf(int bytes, int seed) {
    final rng = Random(seed);
    return Uint8List.fromList(
        List<int>.generate(bytes, (_) => rng.nextInt(256)));
  }

  Future<({int code, String output})> runCli(List<String> args) async {
    debugPrint('[cli] 실행: $args');
    final proc = await Process.start(cliBinary, args,
        environment: {...Platform.environment, 'HOME': peerHome.path});
    proc.stdin.writeln('y'); // TOFU·승인 프롬프트 선응답 (파이프 버퍼링)
    unawaited(proc.stdin.flush());
    final output = StringBuffer();
    final outDone =
        proc.stdout.transform(const SystemEncoding().decoder).forEach(output.write);
    final errDone =
        proc.stderr.transform(const SystemEncoding().decoder).forEach(output.write);
    final code = await proc.exitCode.timeout(const Duration(seconds: 90),
        onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -99;
    });
    await Future.wait([outDone, errDone])
        .timeout(const Duration(seconds: 5), onTimeout: () => const []);
    debugPrint('[cli] 종료 code=$code\n${output.toString().trim()}');
    return (code: code, output: output.toString());
  }

  setUpAll(() async {
    await RustLib.init();
    baseDir = await Directory.systemTemp.createTemp('es-frb-node');
    saveDir = await Directory.systemTemp.createTemp('es-frb-save');
    peerHome = await Directory.systemTemp.createTemp('es-frb-peer');
    node = await nodeStart(
      config: NodeConfig(
        baseDir: baseDir.path,
        saveDir: saveDir.path,
        alias: 'frb-node',
        deviceType: 'desktop',
      ),
      onApproval: (request) {
        debugPrint('[node] 승인 요청: ${request.senderAlias}');
        lastRequest = request;
        return onApproval(request);
      },
    );
    debugPrint('[node] 시작: port=${node.port}');
    nodeSavedEvents().listen((event) {
      debugPrint('[node] 저장 이벤트: ${event.path}');
      savedEvents.add(event);
    });
  });

  tearDownAll(() async {
    await nodeStop().timeout(const Duration(seconds: 10));
  });

  testWidgets('수신: CLI 송신 → 승인 콜백 → 저장 이벤트·바이트 일치·TOFU 기록',
      (tester) async {
    onApproval = (_) async => true;
    lastRequest = null;
    savedEvents.clear();

    final payload = payloadOf(3 << 20, 7);
    final src = File('${peerHome.path}/sample.bin')..writeAsBytesSync(payload);
    final result = await runCli(
        ['send', src.path, '--to', '127.0.0.1:${node.port}', '--alias', 'cli-peer']);
    expect(result.code, 0, reason: result.output);

    expect(lastRequest, isNotNull);
    expect(lastRequest!.senderAlias, 'cli-peer');
    expect(lastRequest!.isNewDevice, true);
    expect(lastRequest!.files.single.name, 'sample.bin');
    expect(lastRequest!.files.single.size, payload.length);

    final saved = File('${saveDir.path}/sample.bin');
    expect(listEquals(saved.readAsBytesSync(), payload), true);

    // 저장 이벤트는 업로드 응답 직후 비동기로 도착한다
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (savedEvents.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    debugPrint('[test1] 저장 이벤트 ${savedEvents.length}건');
    expect(savedEvents.single.fromAlias, 'cli-peer');
    expect(savedEvents.single.path, saved.path);

    final trusted =
        await trustList().timeout(const Duration(seconds: 10));
    debugPrint('[test1] trustList ${trusted.length}건');
    expect(trusted.single.alias, 'cli-peer');
  });

  testWidgets('거절: 승인 콜백 false → CLI에 403', (tester) async {
    onApproval = (_) async => false;
    final src = File('${peerHome.path}/reject.bin')
      ..writeAsBytesSync(payloadOf(1024, 11));
    final result = await runCli(
        ['send', src.path, '--to', '127.0.0.1:${node.port}', '--alias', 'cli-peer']);
    expect(result.code, isNot(0));
    expect(result.output, contains('거절'));
  });

  testWidgets('송신: 탐색 스트림으로 CLI 발견 → sendFiles 진행 이벤트 → 바이트 일치',
      (tester) async {
    final recvDir = await Directory.systemTemp.createTemp('es-frb-recv');
    final proc = await Process.start(
        cliBinary, ['recv', '--dir', recvDir.path, '--alias', 'cli-recv'],
        environment: {...Platform.environment, 'HOME': peerHome.path});
    proc.stdin.writeln('y'); // 수신 승인 선응답
    unawaited(proc.stdin.flush());
    final cliOutput = StringBuffer();
    proc.stdout
        .transform(const SystemEncoding().decoder)
        .listen(cliOutput.write);
    proc.stderr
        .transform(const SystemEncoding().decoder)
        .listen(cliOutput.write);

    try {
      final target = await nodeDeviceEvents()
          .expand((list) => list)
          .firstWhere((d) => d.alias == 'cli-recv')
          .timeout(const Duration(seconds: 20));
      debugPrint('[test3] 발견: ${target.ip}:${target.port}');

      final payload = payloadOf(5 << 20, 21);
      final src = File('${peerHome.path}/outbound.bin')
        ..writeAsBytesSync(payload);

      final events = await sendFiles(
        target: SendTarget(
          ip: target.ip,
          port: target.port,
          fingerprint: target.fingerprint,
          alias: target.alias,
        ),
        paths: [src.path],
      ).toList().timeout(const Duration(seconds: 90));
      debugPrint('[test3] 이벤트 ${events.length}건, 마지막=${events.last.phase}');

      expect(events.first.phase, SendPhase.waitingApproval,
          reason: cliOutput.toString());
      expect(events.last.phase, SendPhase.done, reason: cliOutput.toString());
      final uploading =
          events.where((e) => e.phase == SendPhase.uploading).toList();
      expect(uploading, isNotEmpty);
      expect(uploading.last.sentBytes, payload.length);
      expect(uploading.last.totalBytes, payload.length);

      final received = File('${recvDir.path}/outbound.bin');
      expect(listEquals(received.readAsBytesSync(), payload), true);
    } finally {
      proc.kill();
    }
  });
}
