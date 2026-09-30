import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// A generated self-signed TLS identity.
class TlsIdentity {
  TlsIdentity._(this.context, this.certPem, this.fingerprint);

  /// Ready to pass to [MlfServer.bind].
  final SecurityContext context;

  /// The certificate in PEM form (what gets shown in the pairing QR).
  final String certPem;

  /// SHA-256 over the PEM bytes — the pairing fingerprint both sides verify.
  final String fingerprint;
}

/// Generates an RSA-2048 self-signed certificate valid for [daysValid] days.
///
/// Pairing model (交接文档 §3.1/§7): the client scans the QR containing this
/// fingerprint, pins it, and rejects any later mismatch — no CA needed.
Future<TlsIdentity> generateSelfSignedIdentity({
  String commonName = 'MyLanFiles',
  int daysValid = 3650,
}) async {
  final keyPair = CryptoUtils.generateRSAKeyPair();
  final csr = X509Utils.generateRsaCsrPem(
    {'CN': commonName, 'O': 'MyLanFiles'},
    keyPair.privateKey as RSAPrivateKey,
    keyPair.publicKey as RSAPublicKey,
    san: ['localhost'],
  );

  final certPem = X509Utils.generateSelfSignedCertificate(
    keyPair.privateKey,
    csr,
    daysValid,
    serialNumber: DateTime.now().microsecondsSinceEpoch
        .remainder(1000000000)
        .toString(),
  );

  final fingerprint = fingerprintOfPem(certPem); // hex, 64 chars

  final privatePem = CryptoUtils.encodeRSAPrivateKeyToPem(
    keyPair.privateKey as RSAPrivateKey,
  );
  final context = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(privatePem));
  return TlsIdentity._(context, certPem, fingerprint);
}

/// Convenience: computes our fingerprint definition over any PEM.
String fingerprintOfPem(String pem) =>
    sha256.convert(utf8.encode(pem)).toString();

/// PEM → DER bytes (fingerprint comparisons against system tooling).
Uint8List pemToDer(String pem) => Uint8List.fromList(
  base64.decode(pem.split('\n').where((l) => !l.startsWith('---')).join()),
);
