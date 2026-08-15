import 'dart:convert';

import 'package:easy_send_core/easy_send_core.dart';
import 'package:test/test.dart';

void main() {
  final valid = {
    'app': 'easy-send',
    'version': '1.0',
    'alias': 'mac',
    'deviceType': 'desktop',
    'fingerprint': 'a' * 64,
    'port': 53318,
    'protocol': 'https',
    'announce': true,
  };

  List<int> encode(Map<String, dynamic> json) => utf8.encode(jsonEncode(json));

  test('정상 패킷은 디코딩된다 (encode 왕복)', () {
    final decoded = Announcement.tryDecode(
      Announcement(
        info: DeviceInfo(
          alias: 'mac',
          deviceType: DeviceType.desktop,
          fingerprint: 'a' * 64,
          port: 53318,
        ),
        announce: true,
      ).encode(),
    );
    expect(decoded, isNotNull);
    expect(decoded!.info.alias, 'mac');
    expect(decoded.announce, isTrue);
  });

  // 아래 무시 규칙들은 프로브(정상 피어 간 통신)로는 관찰 불가라 유닛으로 고정.
  test('app이 다르면 무시', () {
    expect(Announcement.tryDecode(encode({...valid, 'app': 'localsend'})),
        isNull);
  });

  test('version 메이저가 다르면 무시, 마이너 차이는 수용', () {
    expect(
        Announcement.tryDecode(encode({...valid, 'version': '2.0'})), isNull);
    expect(Announcement.tryDecode(encode({...valid, 'version': '1.7'})),
        isNotNull);
  });

  test('JSON이 아니거나 필수 필드 타입이 틀리면 무시', () {
    expect(Announcement.tryDecode(utf8.encode('not-json')), isNull);
    expect(
        Announcement.tryDecode(encode({...valid, 'port': '53318'})), isNull);
  });
}
