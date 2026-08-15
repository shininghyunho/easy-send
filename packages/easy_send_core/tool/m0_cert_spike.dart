// M0 스파이크: 순수 Dart로 자체서명 인증서를 만들어 HTTPS 서버를 띄울 수 있는지 검증.
// 성공 기준(PRD 6장 S1): 인증서 생성 → SecurityContext 로드 → HTTPS 기동 →
// 클라이언트 접속 → TLS 채널에서 꺼낸 인증서의 SHA-256 지문이 생성 시 지문과 일치.
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

Future<void> main() async {
  // 1. RSA 2048 키쌍 + CSR + 자체서명 인증서(10년)
  final keyPair = CryptoUtils.generateRSAKeyPair();
  final privateKey = keyPair.privateKey as RSAPrivateKey;
  final publicKey = keyPair.publicKey as RSAPublicKey;

  final csrPem = X509Utils.generateRsaCsrPem(
    {'CN': 'easy-send'},
    privateKey,
    publicKey,
  );
  final certPem = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csrPem,
    3650,
    sans: ['localhost'],
  );
  print('[1] 인증서 생성 OK (${certPem.length} chars)');

  // 2. 생성 시점 지문 = SHA-256(cert DER) — PRD의 기기 ID
  final expectedFingerprint = _fingerprintFromPem(certPem);
  print('[2] 생성 지문: $expectedFingerprint');

  // 3. SecurityContext에 로드 → HTTPS 서버 기동
  final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
  final context = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));
  final server = await HttpServer.bindSecure('127.0.0.1', 0, context);
  server.listen((req) {
    req.response
      ..write('ok')
      ..close();
  });
  print('[3] HTTPS 서버 기동 OK (port ${server.port})');

  // 4. 클라이언트 접속 — badCertificateCallback에서 TLS 채널의 인증서 지문 검증
  String? observedFingerprint;
  final client = HttpClient()
    ..badCertificateCallback = (cert, host, port) {
      observedFingerprint = sha256.convert(cert.der).toString();
      return true;
    };
  final req = await client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/'));
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  client.close();
  await server.close();
  print('[4] 클라이언트 응답: HTTP ${res.statusCode} "$body"');
  print('[4] TLS 채널 지문: $observedFingerprint');

  final pass = body == 'ok' && observedFingerprint == expectedFingerprint;
  print(pass ? 'M0 PASS — 지문 일치, HTTPS 왕복 성공' : 'M0 FAIL');
  exit(pass ? 0 : 1);
}

String _fingerprintFromPem(String pem) {
  final body = pem
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join();
  return sha256.convert(base64.decode(body)).toString();
}
