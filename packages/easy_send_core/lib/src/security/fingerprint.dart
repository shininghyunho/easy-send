import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 지문 = SHA-256(인증서 DER) hex 64자리 — 기기 ID (PRD 4.4).
String fingerprintOfDer(List<int> der) => sha256.convert(der).toString();

String fingerprintOfPem(String pem) {
  // basic_utils가 내는 PEM은 줄 끝이 \r\n이라 trim 없이는 base64 디코딩이 깨진다.
  final body = pem
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join();
  return fingerprintOfDer(base64.decode(body));
}
