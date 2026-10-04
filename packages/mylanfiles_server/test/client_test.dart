import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory serverRoot;
  late Directory inbox;
  late MlfServer server;
  late TlsIdentity identity;
  late MlfClient client;
  late Uri base;

  File put(String name, List<int> bytes) {
    final f = File('${serverRoot.path}/$name');
    f.writeAsBytesSync(bytes);
    return f;
  }

  setUpAll(() async {
    serverRoot = await Directory.systemTemp.createTemp('mlf_client_root');
    inbox = await Directory.systemTemp.createTemp('mlf_client_inbox');
    identity = await generateSelfSignedIdentity();
    server = MlfServer(
      vfs: LocalVfs(root: serverRoot.path),
      serverFingerprint: identity.fingerprint,
    );
    await server.bind(
      InternetAddress.loopbackIPv4,
      0,
      securityContext: identity.context,
    );
    base = Uri.parse('https://127.0.0.1:${server.port}/');
    client = MlfClient(pinnedFingerprint: identity.fingerprint);
    await client.pair(base, 'c' * 64);
  });

  tearDownAll(() async {
    client.close();
    await server.stop();
    await serverRoot.delete(recursive: true);
    await inbox.delete(recursive: true);
  });

  test('MlfPairingInfo parses QR JSON and bare URLs', () {
    final info = MlfPairingInfo.parse(
      '{"v":1,"proto":"mlf","ip":"192.168.1.7","port":51111,"fp":"${'a' * 64}"}',
    );
    expect(info.ip, '192.168.1.7');
    expect(info.port, 51111);
    expect(info.hasFingerprint, isTrue);
    expect(info.baseUri.toString(), 'https://192.168.1.7:51111/');

    final bare = MlfPairingInfo.parse('https://192.168.1.7:51111');
    expect(bare.hasFingerprint, isFalse);
    expect(() => MlfPairingInfo.parse('not a url'), throwsFormatException);
  });

  test(
    'a client pinned to a wrong fingerprint is refused at handshake',
    () async {
      final impostor = MlfClient(pinnedFingerprint: 'd' * 64);
      try {
        // The TLS handshake against the genuine server fails the wrong pin
        // before any HTTP happens.
        await expectLater(impostor.pair(base, 'c' * 64), throwsA(anything));
      } finally {
        impostor.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('list returns entries over https', () async {
    put('hello.txt', utf8.encode('hi there'));
    final entries = await client.list(base, '/');
    expect(entries.any((e) => e.name == 'hello.txt'), isTrue);
  });

  test('read streams with offset (Range resume path)', () async {
    final data = List.generate(100, (i) => i % 256);
    put('blob.bin', data);
    final res = await client.read(base, 'blob.bin', offset: 40);
    final bytes = await res.stream.fold<List<int>>(
      [],
      (acc, chunk) => acc..addAll(chunk),
    );
    expect(bytes, data.sublist(40));
  });

  test('pack + skip: already-owned file produces no frame', () async {
    final a = put('a.txt', utf8.encode('content A'));
    put('b.txt', utf8.encode('content B'));

    // Client already owns a.txt (same content, same name) in its inbox.
    final localA = File('${inbox.path}/a.txt');
    localA.writeAsBytesSync(a.readAsBytesSync());
    final skip = {await sha256FileHex(localA)};

    final reader = await client.pack(base, ['a.txt', 'b.txt'], skip: skip);

    final received = <String, List<int>>{};
    var frames = 0;
    while (true) {
      final frame = await reader.next();
      if (frame == null) {
        break;
      }
      frames++;
      final chunks = await frame.data.fold<List<int>>(
        [],
        (acc, c) => acc..addAll(c),
      );
      received[frame.name] = chunks;
    }
    await reader.cancel();

    expect(frames, 1, reason: 'a.txt is skipped, only b.txt travels');
    expect(received.containsKey('a.txt'), isFalse);
    expect(utf8.decode(received['b.txt']!), 'content B');

    // Landing it in the inbox and re-requesting with the refreshed skip set
    // now skips everything — the stream is just the terminator.
    final localB = File('${inbox.path}/b.txt');
    localB.writeAsBytesSync(received['b.txt']!);
    final skip2 = {await sha256FileHex(localA), await sha256FileHex(localB)};
    final reader2 = await client.pack(base, ['a.txt', 'b.txt'], skip: skip2);
    expect(await reader2.next(), isNull);
    await reader2.cancel();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'upload: lands atomically, resumes from remote part (R-013 paths)',
    () async {
      final src = File('${serverRoot.path}/upload-src.bin');
      src.writeAsBytesSync(List.generate(50000, (i) => i % 251));

      // 1) full upload to /updir/
      var lastSent = -1;
      await client.upload(
        base,
        src,
        '/updir',
        onProgress: (s, t) => lastSent = s,
      );
      expect(lastSent, 50000);
      final entries = await client.list(base, '/updir');
      expect(
        entries.map((e) => e.name),
        allOf(
          contains('upload-src.bin'),
          isNot(contains('upload-src.bin.mlfpart')),
        ),
      );

      // 2) simulate an interrupted upload: remote part holding half the bytes
      await client.op(base, 'delete', {'path': '/updir/upload-src.bin'});
      final half = File('${serverRoot.path}/half.bin');
      half.writeAsBytesSync(src.readAsBytesSync().sublist(0, 25000));
      await client.upload(base, half, '/updir');
      await client.op(base, 'rename', {
        'path': '/updir/half.bin',
        'newName': 'upload-src.bin.mlfpart',
      });

      // 3) re-upload resumes from 25000 — the wire only carries the tail.
      var firstProgress = -1;
      await client.upload(
        base,
        src,
        '/updir',
        onProgress: (s, t) =>
            firstProgress = firstProgress < 0 ? s : firstProgress,
      );
      expect(
        firstProgress,
        25000,
        reason: 'resume must start at the part size',
      );

      final finalEntries = await client.list(base, '/updir');
      expect(
        finalEntries.firstWhere((e) => e.name == 'upload-src.bin').size,
        50000,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('countBytes reports every byte exactly once', () async {
    var counted = 0;
    final src = Stream<List<int>>.fromIterable([
      Uint8List.fromList([1, 2, 3]),
      Uint8List.fromList([4, 5]),
    ]);
    final out = await countBytes(
      src,
      (d) => counted += d,
    ).fold<List<int>>([], (a, c) => a..addAll(c));
    expect(counted, 5);
    expect(out, [1, 2, 3, 4, 5]);
  });
}
