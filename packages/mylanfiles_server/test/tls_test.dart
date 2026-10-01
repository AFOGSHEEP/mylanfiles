import 'dart:io';

import 'package:http/io_client.dart';
import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';
import 'package:test/test.dart';

void main() {
  test('self-signed identity works end-to-end over https', () async {
    final identity = await generateSelfSignedIdentity();
    expect(identity.fingerprint, hasLength(64));
    expect(identity.certPem, contains('BEGIN CERTIFICATE'));

    final tmp = await Directory.systemTemp.createTemp('mlf_tls_test');
    try {
      final server = MlfServer(
        vfs: LocalVfs(root: tmp.path),
        serverFingerprint: identity.fingerprint,
        pairedFingerprints: {'b' * 64},
        allowPairing: false,
      );
      await server.bind(
        InternetAddress.loopbackIPv4,
        0,
        securityContext: identity.context,
      );

      // The fingerprint is defined over DER, so a client recomputes it
      // directly from the X509Certificate presented in the handshake.
      expect(fingerprintOfPem(identity.certPem), identity.fingerprint);
      final inner = HttpClient()
        ..badCertificateCallback = (cert, host, port) =>
            fingerprintOfDer(cert.der) == identity.fingerprint;
      final client = IOClient(inner);
      try {
        final res = await client.get(
          Uri.parse('https://127.0.0.1:${server.port}/api/v1/fs/list'),
          headers: {'x-mlf-fingerprint': 'b' * 64},
        );
        expect(res.statusCode, 200);
      } finally {
        client.close();
        await server.stop();
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'a client pinned to a different fingerprint rejects the handshake',
    () async {
      final identity = await generateSelfSignedIdentity();
      final tmp = await Directory.systemTemp.createTemp('mlf_tls_test');
      try {
        final server = MlfServer(
          vfs: LocalVfs(root: tmp.path),
          serverFingerprint: identity.fingerprint,
          pairedFingerprints: {'b' * 64},
          allowPairing: false,
        );
        await server.bind(
          InternetAddress.loopbackIPv4,
          0,
          securityContext: identity.context,
        );
        final inner = HttpClient()
          ..badCertificateCallback = (cert, host, port) =>
              fingerprintOfDer(cert.der) == 'a' * 64; // wrong pin
        final client = IOClient(inner);
        try {
          await expectLater(
            client.get(
              Uri.parse('https://127.0.0.1:${server.port}/api/v1/fs/list'),
              headers: {'x-mlf-fingerprint': 'b' * 64},
            ),
            throwsA(anything),
          );
        } finally {
          client.close();
          await server.stop();
        }
      } finally {
        await tmp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('loadOrCreateIdentity persists the fingerprint across loads', () async {
    final tmp = await Directory.systemTemp.createTemp('mlf_tls_store');
    try {
      final first = await loadOrCreateIdentity(tmp);
      final second = await loadOrCreateIdentity(tmp);
      expect(second.fingerprint, first.fingerprint);

      final other = await loadOrCreateIdentity(Directory('${tmp.path}/other'));
      expect(other.fingerprint, isNot(first.fingerprint));

      expect(first.privateKeyPem, contains('PRIVATE KEY'));
    } finally {
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
