import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';

import 'fingerprint.dart';

/// 기기 신원 = 키쌍 + 자체서명 인증서 (PRD 4.4). 최초 실행 시 생성해 파일로 영속.
class DeviceIdentity {
  DeviceIdentity._({required this.certificatePem, required this.privateKeyPem})
      : fingerprint = fingerprintOfPem(certificatePem);

  final String certificatePem;
  final String privateKeyPem;

  /// 기기 ID. SHA-256(인증서 DER) hex 64자리.
  final String fingerprint;

  static const _certFileName = 'identity_cert.pem';
  static const _keyFileName = 'identity_key.pem';

  static DeviceIdentity generate() {
    final keyPair = CryptoUtils.generateRSAKeyPair();
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final csrPem = X509Utils.generateRsaCsrPem(
      {'CN': 'easy-send'},
      privateKey,
      keyPair.publicKey as RSAPublicKey,
    );
    return DeviceIdentity._(
      certificatePem:
          X509Utils.generateSelfSignedCertificate(privateKey, csrPem, 3650),
      privateKeyPem: CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
    );
  }

  static Future<DeviceIdentity> loadOrCreate(Directory dir) async {
    final certFile = File('${dir.path}/$_certFileName');
    final keyFile = File('${dir.path}/$_keyFileName');
    if (certFile.existsSync() && keyFile.existsSync()) {
      return DeviceIdentity._(
        certificatePem: certFile.readAsStringSync(),
        privateKeyPem: keyFile.readAsStringSync(),
      );
    }
    final identity = generate();
    await dir.create(recursive: true);
    certFile.writeAsStringSync(identity.certificatePem);
    keyFile.writeAsStringSync(identity.privateKeyPem);
    return identity;
  }

  SecurityContext serverContext() => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
}
