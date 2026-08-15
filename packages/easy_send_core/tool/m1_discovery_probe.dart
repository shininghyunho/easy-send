// M1 검증 프로브: 인스턴스 1개를 띄워 발견한 기기 목록 변화를 시간과 함께 출력.
// 사용: dart run tool/m1_discovery_probe.dart <alias> <수명 초>
// 두 터미널(프로세스)에서 각각 실행해 상호 발견·TTL 제거를 관찰한다.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easy_send_core/easy_send_core.dart';

Future<void> main(List<String> args) async {
  final alias = args[0];
  final lifetime = Duration(seconds: int.parse(args[1]));

  // 실제 앱에선 인증서 지문. 프로브는 프로세스마다 달라지기만 하면 된다.
  final fingerprint = sha256.convert(utf8.encode('$alias-$pid')).toString();
  final service = DiscoveryService(
    self: DeviceInfo(
      alias: alias,
      deviceType: DeviceType.desktop,
      fingerprint: fingerprint,
      port: Protocol.defaultServicePort,
    ),
  );

  final startedAt = DateTime.now();
  String elapsed() =>
      (DateTime.now().difference(startedAt).inMilliseconds / 1000)
          .toStringAsFixed(1);

  service.devices.listen((devices) {
    print('[$alias +${elapsed()}s] devices: $devices');
  });
  await service.start();
  print('[$alias +0.0s] started (pid $pid)');

  await Future<void>.delayed(lifetime);
  service.stop();
  print('[$alias +${elapsed()}s] stopped');
}
