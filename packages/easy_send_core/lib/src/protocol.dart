/// 프로토콜 상수 — PRD 4.1. LocalSend(224.0.0.167:53317)와 충돌을 피해 +1씩 오프셋.
abstract final class Protocol {
  static const app = 'easy-send';
  static const version = '1.0';
  static const scheme = 'https';

  static const multicastGroup = '224.0.0.168';
  static const discoveryPort = 53318;
  static const defaultServicePort = 53318;

  static const announceInterval = Duration(seconds: 5);
  static const deviceTtl = Duration(seconds: 15);

  static String get versionMajor => version.split('.').first;
}
