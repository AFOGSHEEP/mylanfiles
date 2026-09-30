import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';
import 'package:test/test.dart';

final _clientFp = 'a' * 64;

void main() {
  late Directory tmp;
  late MlfServer server;
  late http.Client client;
  late Uri base;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('mlf_srv_test');
    await File('${tmp.path}/hello.txt').writeAsString('hello world');
    server = MlfServer(
      vfs: LocalVfs(root: tmp.path),
      serverFingerprint: devFingerprint('server'),
    );
    await server.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    client = http.Client();

    // Pair the test client once, like a QR scan would.
    final pairRes = await client.post(
      base.replace(path: '/api/v1/pair'),
      body: jsonEncode({'fingerprint': _clientFp}),
      headers: {'content-type': 'application/json'},
    );
    expect(pairRes.statusCode, 200);
  });

  tearDownAll(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  setUp(() {
    client = http.Client();
  });
  tearDown(() => client.close());

  http.Request _authed(
    String method,
    String path, {
    Map<String, String> query = const {},
  }) {
    final uri = base.replace(path: path, queryParameters: query);
    return http.Request(method, uri)..headers['x-mlf-fingerprint'] = _clientFp;
  }

  group('auth gate (§7-3)', () {
    test('rejects unpaired requests before any VFS access', () async {
      final res = await client.get(base.replace(path: '/api/v1/fs/list'));
      expect(res.statusCode, 403);
      expect(jsonDecode(res.body)['error'], 'not paired');
    });

    test('rejects malformed fingerprints', () async {
      final req = _authed('GET', '/api/v1/fs/list')
        ..headers['x-mlf-fingerprint'] = 'deadbeef';
      final res = await client.send(req);
      expect(res.statusCode, 403);
    });

    test('blocks an IP after repeated failures (429)', () async {
      final flood = http.Client();
      var saw429 = false;
      for (var i = 0; i < 8; i++) {
        final res = await flood.get(base.replace(path: '/api/v1/fs/list'));
        if (res.statusCode == 429) {
          saw429 = true;
          break;
        }
      }
      flood.close();
      expect(saw429, isTrue);
      server.resetRateLimits(); // don't poison the rest of the suite
    });
  });

  group('fs endpoints (E2E)', () {
    test('list returns entries JSON', () async {
      final res = await client.send(_authed('GET', '/api/v1/fs/list'));
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.stream.bytesToString());
      final names = (body['entries'] as List).map((e) => e['name']);
      expect(names, contains('hello.txt'));
    });

    test('write then read round-trips through HTTP', () async {
      final req = _authed(
        'PUT',
        '/api/v1/fs/write',
        query: {'path': '上传 测试.txt'},
      )..bodyBytes = utf8.encode('你好 MyLanFiles');
      final writeRes = await client.send(req);
      expect(writeRes.statusCode, 200);
      expect(
        jsonDecode(await writeRes.stream.bytesToString())['size'],
        utf8.encode('你好 MyLanFiles').length,
      );

      final readRes = await client.send(
        _authed('GET', '/api/v1/fs/read', query: {'path': '上传 测试.txt'}),
      );
      expect(readRes.statusCode, 200);
      final bytes = await readRes.stream.toBytes();
      expect(utf8.decode(bytes), '你好 MyLanFiles');
      expect(File('${tmp.path}/上传 测试.txt').existsSync(), isTrue);
    });

    test('read honors offset/length (Range semantics)', () async {
      final res = await client.send(
        _authed(
          'GET',
          '/api/v1/fs/read',
          query: {'path': 'hello.txt', 'offset': '6', 'length': '5'},
        ),
      );
      expect(utf8.decode(await res.stream.toBytes()), 'world');
    });

    test('op mkdir → rename → delete', () async {
      Future<http.StreamedResponse> op(Map<String, dynamic> body) => client
          .send(_authed('POST', '/api/v1/fs/op')..body = jsonEncode(body));

      expect(
        (await op({
          'op': 'mkdir',
          'args': {'path': 'docs'},
        })).statusCode,
        200,
      );
      expect(Directory('${tmp.path}/docs').existsSync(), isTrue);

      expect(
        (await op({
          'op': 'rename',
          'args': {'path': 'docs', 'newName': 'documents'},
        })).statusCode,
        200,
      );
      expect(Directory('${tmp.path}/documents').existsSync(), isTrue);

      expect(
        (await op({
          'op': 'delete',
          'args': {'path': 'documents'},
        })).statusCode,
        200,
      );
      expect(Directory('${tmp.path}/documents').existsSync(), isFalse);
    });

    test('unknown op → 400', () async {
      final res = await client.send(
        _authed('POST', '/api/v1/fs/op')
          ..body = jsonEncode({'op': 'format_c', 'args': {}}),
      );
      expect(res.statusCode, 400);
    });
  });

  group('security suite over HTTP (§7)', () {
    test('URL-encoded traversal is rejected (403)', () async {
      final res = await client.send(
        _authed('GET', '/api/v1/fs/list', query: {'path': '../'}),
      );
      expect(res.statusCode, 403);
    });

    test('%2e%2e encoded traversal is rejected (403)', () async {
      final uri = base.replace(
        path: '/api/v1/fs/list',
        query: 'path=%2e%2e%2f%2e%2e%2f',
      ); // ../../../
      final res = await client.send(
        _authed(
          'GET',
          uri.path,
          query: {'path': Uri.parse(uri.toString()).queryParameters['path']!},
        ),
      );
      expect(res.statusCode, 403);
    });

    test('absolute path outside root is rejected (403)', () async {
      final res = await client.send(
        _authed(
          'GET',
          '/api/v1/fs/read',
          query: {'path': 'C:/Windows/win.ini'},
        ),
      );
      expect(res.statusCode, 403);
    });

    test('write outside root is rejected (403)', () async {
      final req = _authed(
        'PUT',
        '/api/v1/fs/write',
        query: {'path': '../evil.txt'},
      )..bodyBytes = utf8.encode('x');
      final res = await client.send(req);
      expect(res.statusCode, 403);
      expect(File('${tmp.parent.path}/evil.txt').existsSync(), isFalse);
    });

    test('read missing → 404, read dir → 409', () async {
      final missing = await client.send(
        _authed('GET', '/api/v1/fs/read', query: {'path': 'nope.bin'}),
      );
      expect(missing.statusCode, 404);

      await Directory('${tmp.path}/adir').create();
      final dir = await client.send(
        _authed('GET', '/api/v1/fs/read', query: {'path': 'adir'}),
      );
      expect(dir.statusCode, 409);
    });
  });
}
