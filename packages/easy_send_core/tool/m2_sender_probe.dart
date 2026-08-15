// M2 송신 프로브: 탐색으로 대상 alias를 찾아 파일들을 전송한다.
// 사용: dart run tool/m2_sender_probe.dart <baseDir> <targetAlias> <파일...>
import 'dart:async';
import 'dart:io';

import 'package:easy_send_core/easy_send_core.dart';

Future<void> main(List<String> args) async {
  final baseDir = Directory(args[0]);
  final targetAlias = args[1];
  final files = args.sublist(2).map(File.new).toList();

  final identity = await DeviceIdentity.loadOrCreate(baseDir);
  final trustStore = TrustStore(File('${baseDir.path}/trusted.json'));
  final self = DeviceInfo(
    alias: 'sender',
    deviceType: DeviceType.desktop,
    fingerprint: identity.fingerprint,
    port: Protocol.defaultServicePort,
  );

  final discovery = DiscoveryService(self: self);
  final found = Completer<DiscoveredDevice>();
  discovery.devices.listen((devices) {
    for (final d in devices) {
      if (d.info.alias == targetAlias && found.isCompleted == false) {
        found.complete(d);
      }
    }
  });
  await discovery.start();
  final target = await found.future.timeout(const Duration(seconds: 15));
  discovery.stop();
  print('[sender] 발견: $target');

  if (trustStore.contains(target.info.fingerprint) == false) {
    print('[sender] 새 기기 → 신뢰 확인(자동 승인) 후 저장');
    await trustStore.add(target.info.fingerprint, target.info.alias);
  }

  final client = SendClient(
    address: target.address.address,
    port: target.info.port,
    expectedFingerprint: target.info.fingerprint,
  );
  final metas = <String, FileMeta>{
    for (var i = 0; i < files.length; i++)
      'f$i': FileMeta(
        name: files[i].uri.pathSegments.last,
        size: files[i].lengthSync(),
        mime: 'application/octet-stream',
      ),
  };
  final sw = Stopwatch()..start();
  final session = await client.prepareUpload(self, metas);
  print('[sender] 승인됨 (sessionId ${session.sessionId.substring(0, 8)}…)');
  for (var i = 0; i < files.length; i++) {
    await client.uploadFile(session, 'f$i', files[i]);
    print('[sender] 업로드 완료: ${metas['f$i']!.name} (${metas['f$i']!.size} bytes)');
  }
  final totalBytes = metas.values.fold(0, (sum, m) => sum + m.size);
  final mbps = totalBytes / 1024 / 1024 / (sw.elapsedMilliseconds / 1000);
  print('[sender] 전체 완료: $totalBytes bytes, ${sw.elapsedMilliseconds}ms '
      '(${mbps.toStringAsFixed(1)} MB/s)');
  client.close();
}
