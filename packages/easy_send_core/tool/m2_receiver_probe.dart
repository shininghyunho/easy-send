// M2 수신 프로브: 신원 생성 → HTTPS 수신 서버 → 탐색 announce. 승인 요청을
// 출력하고 자동 승인한다(실제 앱에선 다이얼로그).
// 사용: dart run tool/m2_receiver_probe.dart <baseDir> <alias> <수명 초>
import 'dart:io';

import 'package:easy_send_core/easy_send_core.dart';

Future<void> main(List<String> args) async {
  final baseDir = Directory(args[0]);
  final alias = args[1];
  final lifetime = Duration(seconds: int.parse(args[2]));

  final identity = await DeviceIdentity.loadOrCreate(baseDir);
  final trustStore = TrustStore(File('${baseDir.path}/trusted.json'));
  final saveDir = Directory('${baseDir.path}/received')..createSync();

  late final ReceiveServer server;
  late final DeviceInfo self;
  server = ReceiveServer(
    identity: identity,
    self: self = DeviceInfo(
      alias: alias,
      deviceType: DeviceType.desktop,
      fingerprint: identity.fingerprint,
      port: 0,
    ),
    trustStore: trustStore,
    saveDir: saveDir,
    onApprovalRequest: (req) async {
      final label = req.isNewDevice ? '새 기기' : '알던 기기';
      print('[$alias] 승인 요청: ${req.sender.alias}($label) '
          '파일 ${req.files.length}개 → 승인');
      return true;
    },
    onFileSaved: (fileId, saved) =>
        print('[$alias] 저장: $fileId → ${saved.path}'),
    onSessionDone: () => print('[$alias] 세션 완료'),
  );
  await server.start();

  final discovery = DiscoveryService(
    self: DeviceInfo(
      alias: self.alias,
      deviceType: self.deviceType,
      fingerprint: self.fingerprint,
      port: server.port,
    ),
  );
  await discovery.start();
  print('[$alias] 수신 대기 (port ${server.port}, 지문 ${identity.fingerprint.substring(0, 12)}…)');

  await Future<void>.delayed(lifetime);
  discovery.stop();
  await server.stop();
}
