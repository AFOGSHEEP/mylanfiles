import 'dart:io';

import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late MlfServer server;
  late Uri base;
  final fp = devFingerprint('media-client');

  File put(String rel, List<int> bytes, {DateTime? mtime}) {
    final f = File('${root.path}/$rel')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    if (mtime != null) {
      f.setLastModifiedSync(mtime);
    }
    return f;
  }

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('mlf_media');
    // 桶结构:DCIM(嵌套)、Pictures、Downloads(非桶,Download 才是)、Movies
    put('DCIM/Camera/IMG_0001.jpg', [1]);
    put('DCIM/Camera/IMG_0002.jpg', [2], mtime: DateTime(2026, 1, 1));
    put('DCIM/Camera/video.mp4', [3]);
    put('DCIM/deep/a/b/c/too-deep.jpg', [4]); // 深度 4 → 不可见
    put('Pictures/屏幕截图 2026.png', [5]);
    put('Pictures/song.mp3', [6]);
    put('Download/doc.pdf', [7]); // 非媒体
    await Directory('${root.path}/Screenshots').create(recursive: true);

    server = MlfServer(
      vfs: LocalVfs(root: root.path),
      serverFingerprint: fp,
    );
    await server.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    final client = MlfClient(pinnedFingerprint: fp);
    await client.pair(base, fp);
    _client = client;
  });

  tearDownAll(() async {
    _client?.close();
    await server.stop();
    await root.delete(recursive: true);
  });

  test(
    'bucket discovery: only known, existing buckets; no host paths leak',
    () async {
      final res = await _client!.getJson(base, 'media/list');
      final buckets = (res['buckets'] as List)
          .map((b) => (b as Map)['name'] as String)
          .toList();
      expect(
        buckets,
        containsAll(['DCIM', 'Pictures', 'Download', 'Screenshots']),
      );
      expect(buckets, isNot(contains('Movies'))); // 不存在
      for (final b in res['buckets'] as List) {
        expect((b as Map)['path'] as String, startsWith('/')); // 虚拟路径
        expect(
          b['path'].toString(),
          isNot(contains(root.path.split('/').last)),
        );
      }
    },
  );

  test('bucket content: type filter, depth cap, mtime desc', () async {
    final res = await _client!.getJson(
      base,
      'media/list?bucket=DCIM&type=image',
    );
    final entries = (res['entries'] as List).cast<Map>();
    expect(res['total'], 2); // 两张 jpg;too-deep 深度 4 不可见
    expect(entries.map((e) => e['name']), isNot(contains('too-deep.jpg')));
    expect(entries.map((e) => e['kind']), everyElement('image'));
    // mtime 倒序:IMG_0001(今天)> IMG_0002(2026-01-01)
    expect(entries.first['name'], 'IMG_0001.jpg');
  });

  test('type=video and bucket=Pictures audio', () async {
    final v = await _client!.getJson(base, 'media/list?bucket=DCIM&type=video');
    expect(v['total'], 1);
    expect((v['entries'] as List).first['name'], 'video.mp4');

    final a = await _client!.getJson(
      base,
      'media/list?bucket=Pictures&type=audio',
    );
    expect(a['total'], 1);
    expect((a['entries'] as List).first['name'], 'song.mp3');
  });

  test('non-media extensions are excluded from any', () async {
    final res = await _client!.getJson(base, 'media/list?bucket=Download');
    expect(res['total'], 0, reason: 'doc.pdf 不是媒体');
  });

  test('since filter and pagination', () async {
    final since = DateTime(2026, 6, 1).millisecondsSinceEpoch;
    final res = await _client!.getJson(
      base,
      'media/list?bucket=DCIM&type=image&since=$since',
    );
    expect(res['total'], 1); // 只有 IMG_0001 是新的
    expect((res['entries'] as List).first['name'], 'IMG_0001.jpg');

    final page = await _client!.getJson(
      base,
      'media/list?bucket=DCIM&limit=1&offset=1',
    );
    expect(page['total'], 3); // 不分类型:2 jpg + 1 mp4
    expect((page['entries'] as List).length, 1);
  });

  test('unknown bucket → 404; traversal-shaped bucket → 404', () async {
    expect(
      () => _client!.getJson(base, 'media/list?bucket=Nope'),
      throwsA(isA<MlfClientException>()),
    );
    expect(
      () => _client!.getJson(base, 'media/list?bucket=..%2F..'),
      throwsA(isA<MlfClientException>()),
    );
  });
}

MlfClient? _client;
