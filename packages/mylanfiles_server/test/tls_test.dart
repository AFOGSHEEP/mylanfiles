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

      // A real client would pin `identity.fingerprint` from the QR and accept
      // the cert only when its fingerprint matches; the test accepts it after
      // asserting the fingerprint algorithm is deterministic.
      expect(fingerprintOfPem(identity.certPem), identity.fingerprint);
      final inner = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
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
}
