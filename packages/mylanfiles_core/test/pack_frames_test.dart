import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:test/test.dart';

Uint8List _sha(List<int> data) =>
    Uint8List.fromList(sha256.convert(data).bytes);

/// 组装一条完整的打包流字节序列。
List<int> buildStream(
  List<(String, List<int>)> files, {
  Set<int> skipIdx = const {},
}) {
  final out = BytesBuilder();
  for (var i = 0; i < files.length; i++) {
    final (name, data) = files[i];
    final sha = _sha(data);
    if (skipIdx.contains(i)) continue; // server-side skip: no frame at all
    out.add(encodeFrameHeader(name, data.length, sha));
    out.add(data);
  }
  out.add(encodeStreamEnd());
  return out.toBytes();
}

void main() {
  group('frames', () {
    test('encodes header with UTF-8 name length', () {
      final sha = Uint8List.fromList(List.generate(32, (i) => i));
      final header = encodeFrameHeader('照片.jpg', 123456, sha);
      final nameLen = ByteData.sublistView(
        Uint8List.fromList(header),
      ).getUint32(0, Endian.little);
      expect(nameLen, utf8.encode('照片.jpg').length);
    });

    test('round-trips multiple files in one stream', () async {
      final files = [
        ('a.txt', utf8.encode('alpha')),
        ('中文 目录/旅行照片.jpg', List.generate(1000, (i) => i % 256)),
        ('empty.bin', <int>[]),
      ];
      final stream = buildStream(files);
      final reader = PackStreamReader(Stream.value(stream));

      var i = 0;
      while (true) {
        final frame = await reader.next();
        if (frame == null) break;
        expect(frame.name, files[i].$1, reason: 'file $i');
        final got = await frame.data.expand((c) => c).toList();
        expect(got, files[i].$2, reason: 'content $i');
        expect(frame.shaHex, toHex(_sha(files[i].$2)));
        i++;
      }
      expect(i, files.length);
      await reader.cancel();
    });

    test('skip set drops frames by sha', () async {
      final files = [
        ('keep.txt', utf8.encode('keep')),
        ('skipme.txt', utf8.encode('this one is skipped')),
        ('also-keep.txt', utf8.encode('also here')),
      ];
      final skipSha = toHex(_sha(files[1].$2));
      // Stream contains the frame; client-side skip drains it silently.
      final stream = buildStream(files);
      final reader = PackStreamReader(Stream.value(stream));

      final names = <String>[];
      while (true) {
        final frame = await reader.next(skip: {skipSha});
        if (frame == null) break;
        names.add(frame.name);
        await frame.data.drain<void>();
      }
      expect(names, ['keep.txt', 'also-keep.txt']);
    });

    test('truncated stream raises PackFormatException', () async {
      final files = [('x.txt', List.generate(500, (i) => i))];
      final stream = List<int>.of(buildStream(files));
      stream.removeRange(20, stream.length);
      final reader = PackStreamReader(Stream.value(stream));
      await expectLater(reader.next(), throwsA(isA<PackFormatException>()));
    });

    test('large random file streams through without full buffering', () async {
      // 4 MB — bigger than any single chunk; guards the buffer-append logic.
      final rng = Random(42);
      final data = List.generate(4 << 20, (_) => rng.nextInt(256));
      final stream = buildStream([('big.bin', data)]);
      final reader = PackStreamReader(Stream.value(stream));
      final frame = await reader.next();
      final got = await frame!.data.expand((c) => c).toList();
      expect(got.length, data.length);
      expect(toHex(_sha(got)), toHex(_sha(data)));
      expect(await reader.next(), isNull);
    });

    test('chunked delivery across odd boundaries works', () async {
      final data = List.generate(97, (i) => i);
      final stream = buildStream([('odd.bin', data)]);
      // Deliver in 7-byte chunks to stress the buffer compaction.
      final chunks = <List<int>>[];
      for (var i = 0; i < stream.length; i += 7) {
        chunks.add(stream.sublist(i, min(i + 7, stream.length)));
      }
      final reader = PackStreamReader(Stream.fromIterable(chunks));
      final frame = await reader.next();
      expect(await frame!.data.expand((c) => c).toList(), data);
    });
  });
}
