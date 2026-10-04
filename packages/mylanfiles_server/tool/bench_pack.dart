// 打包流 vs 逐文件请求 基准测试（复现可行性报告 §16.2 的 M1 实验，Windows 本机）
//
// 场景：300 × 8KB（模拟截图/微信图片）+ 10 × 1MB（混合）
// 模式：
//   A. 逐文件 GET /api/v1/fs/read（每请求一次往返）
//   B. 同 A + 每请求前模拟 3ms RTT（Wi-Fi 往返模型）
//   C. 打包流 POST /api/v1/pack（单请求连续帧）
//   D. 大文件单流 GET（2×256MB）——测 fs/read 吞吐上限
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';

const smallCount = 300;
const smallSize = 8 * 1024;
const midCount = 10;
const midSize = 1024 * 1024;
const bigSize = 256 * 1024 * 1024;
const simulatedRtt = Duration(milliseconds: 3);

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('mlf_bench');
  final names = <String>[];
  final rng = Random(7);
  final chunk = List<int>.generate(smallSize, (_) => rng.nextInt(256));
  for (var i = 0; i < smallCount; i++) {
    final name = 's$i.bin';
    await File('${tmp.path}/$name').writeAsBytes(chunk);
    names.add(name);
  }
  final midChunk = List<int>.generate(midSize, (_) => rng.nextInt(256));
  for (var i = 0; i < midCount; i++) {
    final name = 'm$i.bin';
    await File('${tmp.path}/$name').writeAsBytes(midChunk);
    names.add(name);
  }
  final totalBytes = smallCount * smallSize + midCount * midSize;

  final server = MlfServer(
    vfs: LocalVfs(root: tmp.path),
    serverFingerprint: 'a' * 64,
  );
  await server.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  final client = http.Client();
  await client.post(
    Uri.parse('$base/api/v1/pair'),
    body: jsonEncode({'fingerprint': 'a' * 64}),
  );
  final headers = {'x-mlf-fingerprint': 'a' * 64};

  Future<void> perFile({required bool rtt}) async {
    for (final name in names) {
      if (rtt) {
        await Future<void>.delayed(simulatedRtt);
      }
      final res = await client.get(
        Uri.parse('$base/api/v1/fs/read?path=$name'),
        headers: headers,
      );
      if (res.statusCode != 200) {
        throw 'read $name -> ${res.statusCode}';
      }
    }
  }

  Future<void> packStream() async {
    final res = await client.send(
      http.Request('POST', Uri.parse('$base/api/v1/pack'))
        ..headers['x-mlf-fingerprint'] = 'a' * 64
        ..body = jsonEncode({'items': names, 'skip': []}),
    );
    if (res.statusCode != 200) {
      throw 'pack -> ${res.statusCode}';
    }
    final reader = PackStreamReader(res.stream);
    var n = 0;
    while (true) {
      final frame = await reader.next();
      if (frame == null) {
        break;
      }
      await frame.data.drain<void>();
      n++;
    }
    if (n != names.length) {
      throw 'pack got $n frames, want ${names.length}';
    }
  }

  Future<void> bench(String label, Future<void> Function() fn) async {
    // warm-up (JIT + connection pool)
    await fn();
    final sw = Stopwatch()..start();
    await fn();
    sw.stop();
    final mbps = totalBytes / 1024 / 1024 / (sw.elapsedMicroseconds / 1e6);
    stdout.writeln(
      '$label: ${sw.elapsedMilliseconds} ms  => ${mbps.toStringAsFixed(1)} MB/s',
    );
  }

  print(
    'files=$smallCount x ${smallSize ~/ 1024}KB + $midCount x 1MB, '
    'total=${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
  );
  stdout.writeln('setup done, benches starting...');
  await bench('A 逐文件 (无RTT)      ', () => perFile(rtt: false));
  await bench('B 逐文件 (模拟3ms RTT)', () => perFile(rtt: true));
  await bench('C 打包流 (单请求)     ', packStream);

  // D. 大文件单流吞吐
  final big = List<int>.generate(1 << 20, (_) => rng.nextInt(256));
  final bigPath = '${tmp.path}/big.bin';
  final raf = File(bigPath).openSync(mode: FileMode.write);
  for (var i = 0; i < bigSize >> 20; i++) {
    raf.writeFromSync(big);
  }
  await raf.close();
  {
    final sw = Stopwatch()..start();
    final res = await client.send(
      http.Request('GET', Uri.parse('$base/api/v1/fs/read?path=big.bin'))
        ..headers.addAll(headers),
    );
    final got = await res.stream.toBytes();
    sw.stop();
    stdout.writeln(
      'D 大文件单流 (${got.length ~/ 1024 / 1024}MB): ${sw.elapsedMilliseconds} ms '
      '=> ${(bigSize / 1024 / 1024 / (sw.elapsedMicroseconds / 1e6)).toStringAsFixed(0)} MB/s',
    );
  }

  await server.stop();
  await tmp.delete(recursive: true);
}
