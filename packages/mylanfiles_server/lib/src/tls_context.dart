import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// A self-signed TLS identity (certificate + private key + ready context).
class TlsIdentity {
  TlsIdentity._(
    this.context,
    this.certPem,
    this.privateKeyPem,
    this.fingerprint,
  );

  /// Ready to pass to [MlfServer.bind].
  final SecurityContext context;

  /// The certificate in PEM form.
  final String certPem;

  /// The private key in PEM form (persist alongside [certPem] to keep the
  /// identity — and therefore the pairing fingerprint — stable across runs).
  final String privateKeyPem;

  /// SHA-256 over the certificate DER bytes — the pairing fingerprint both
  /// sides verify. DER (not PEM) so a client can recompute it directly from
  /// the `X509Certificate.der` presented in the TLS handshake (QR pinning).
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
  final privatePem = CryptoUtils.encodeRSAPrivateKeyToPem(
    keyPair.privateKey as RSAPrivateKey,
  );

  return identityFromPem(certPem, privatePem);
}

/// Builds a [TlsIdentity] from existing PEMs (e.g. loaded from disk).
TlsIdentity identityFromPem(String certPem, String privateKeyPem) {
  final fingerprint = fingerprintOfDer(pemToDer(certPem));
  final context = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
  return TlsIdentity._(context, certPem, privateKeyPem, fingerprint);
}

/// Loads a persisted identity from [storeDir] (`tls_identity.json`), creating
/// and persisting a fresh one when absent — so the QR fingerprint survives
/// restarts and previously paired clients stay valid.
Future<TlsIdentity> loadOrCreateIdentity(Directory storeDir) async {
  if (!storeDir.existsSync()) {
    storeDir.createSync(recursive: true);
  }
  final file = File('${storeDir.path}/tls_identity.json');
  if (file.existsSync()) {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<dynamic, dynamic>;
      return identityFromPem(
        json['certPem'] as String,
        json['privateKeyPem'] as String,
      );
    } on Object {
      // Corrupt store — fall through and regenerate.
    }
  }
  final identity = await generateSelfSignedIdentity();
  file.writeAsStringSync(
    jsonEncode({
      'certPem': identity.certPem,
      'privateKeyPem': identity.privateKeyPem,
    }),
    flush: true,
  );
  return identity;
}

/// Our pairing fingerprint definition: SHA-256 hex over DER bytes.
String fingerprintOfDer(Uint8List der) => sha256.convert(der).toString();

/// Convenience over a PEM (kept for comparing against system tooling output).
String fingerprintOfPem(String pem) => fingerprintOfDer(pemToDer(pem));

/// PEM → DER bytes. Tolerates CRLF and basic_utils' non-standard unspaced
/// `-----ENDCERTIFICATE-----` markers.
Uint8List pemToDer(String pem) {
  final flat = pem.replaceAll(RegExp(r'\s'), '');
  final body = flat.replaceAll(RegExp(r'-{2,}(BEGIN|END)[A-Z]*-{2,}'), '');
  return Uint8List.fromList(base64.decode(body));
}
