/// 打包流帧编解码（交接文档 §4.2，决策级格式）：
///
/// ```
/// 每帧 = [4B nameLen LE][name UTF-8][8B size LE][32B SHA-256][数据]
/// 流尾 = nameLen == 0（空帧）
/// ```
///
/// 文件粒度断点续传：客户端先发 skip（已有文件的 SHA 列表），服务端跳过
/// 已存在帧——重传只补缺，无需字节级断点。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

const packShaBytes = 32;
const _u32 = 4;
const _u64 = 8;

/// 编码一帧的头部（数据部分由调用方紧接着写入流）。
Uint8List encodeFrameHeader(String name, int size, Uint8List sha256) {
  if (sha256.length != packShaBytes) {
    throw ArgumentError.value(sha256.length, 'sha256', 'must be 32 bytes');
  }
  final nameBytes = utf8.encode(name);
  final out = BytesBuilder();
  final u32 = ByteData(_u32)..setUint32(0, nameBytes.length, Endian.little);
  out.add(u32.buffer.asUint8List());
  out.add(nameBytes);
  final u64 = ByteData(_u64)..setUint64(0, size, Endian.little);
  out.add(u64.buffer.asUint8List());
  out.add(sha256);
  return out.toBytes();
}

/// 流尾空帧。
Uint8List encodeStreamEnd() => Uint8List(_u32);

/// 一帧已解析出的元信息；数据经 [data] 流式给出（长度恒等于 [size]）。
///
/// 协议约束：必须先完整消费 [data] 再调用 [PackStreamReader.next]。
class PackFrame {
  PackFrame(this.name, this.size, this.sha256, this.data);

  final String name;
  final int size;

  /// Raw 32 bytes; use [shaHex] for skip-set comparison.
  final Uint8List sha256;

  final Stream<List<int>> data;

  String get shaHex => toHex(sha256);
}

String toHex(Uint8List bytes) {
  const digits = '0123456789abcdef';
  final b = StringBuffer();
  for (final byte in bytes) {
    b.write(digits[(byte >> 4) & 0xf]);
    b.write(digits[byte & 0xf]);
  }
  return b.toString();
}

Uint8List hexToBytes(String hex) {
  if (hex.length.isOdd) throw FormatException('odd hex length');
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 流式解析打包流。pull 式：[next] 逐帧返回，数据不整体进内存。
class PackStreamReader {
  PackStreamReader(Stream<List<int>> source)
    : _it = StreamIterator<List<int>>(source);

  final StreamIterator<List<int>> _it;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;
  bool _sourceDone = false;
  bool _done = false;
  String? _pendingFrame;

  /// 下一帧；流结束（空帧）返回 null。skip 中的 SHA 十六进制会被静默跳过。
  ///
  /// 上一帧的 [PackFrame.data] 必须先消费完（或 [cancel]），否则抛
  /// [PackFormatException]——substream 是惰性的，这里显式拦住顺序错误。
  Future<PackFrame?> next({Set<String> skip = const {}}) async {
    if (_pendingFrame != null) {
      throw PackFormatException(
        'previous frame "$_pendingFrame" data not consumed before next()',
      );
    }
    while (!_done) {
      final nameLen = await readU32();
      if (nameLen == 0) {
        _done = true;
        return null;
      }
      if (nameLen > (1 << 20)) {
        throw PackFormatException('frame name too long: $nameLen');
      }
      final name = utf8.decode(await readBytes(nameLen));
      final size = await readU64();
      final sha = await readBytes(packShaBytes);
      if (skip.contains(toHex(sha))) {
        await drain(size);
        continue;
      }
      _pendingFrame = name;
      return PackFrame(name, size, sha, _guardConsumed(substream(size), name));
    }
    return null;
  }

  /// Clears [_pendingFrame] when the frame's data stream is fully consumed,
  /// cancelled, or errors.
  Stream<List<int>> _guardConsumed(
    Stream<List<int>> inner,
    String name,
  ) async* {
    try {
      yield* inner;
      _pendingFrame = null;
    } on Object {
      _pendingFrame = null;
      rethrow;
    }
  }

  /// 提前终止时关闭底层流。
  Future<void> cancel() => _it.cancel();

  // ---- internals ----

  Future<Uint8List> readBytes(int n) async {
    if (!await _ensure(n)) {
      throw PackFormatException('unexpected EOF (want $n bytes)');
    }
    final view = Uint8List.sublistView(_buf, _pos, _pos + n);
    _pos += n;
    return view;
  }

  Future<int> readU32() async {
    final b = await readBytes(_u32);
    return ByteData.sublistView(b).getUint32(0, Endian.little);
  }

  Future<int> readU64() async {
    final b = await readBytes(_u64);
    return ByteData.sublistView(b).getUint64(0, Endian.little);
  }

  Future<void> drain(int n) async {
    var left = n;
    while (left > 0) {
      if (_remaining == 0 && !await _ensure(1)) {
        throw PackFormatException('unexpected EOF while skipping');
      }
      final take = min(left, _remaining);
      _pos += take;
      left -= take;
    }
  }

  /// 返回正好 [n] 字节的子流（消费期间独占 reader 状态）。
  Stream<List<int>> substream(int n) async* {
    var left = n;
    while (left > 0) {
      if (_remaining == 0 && !await _ensure(1)) {
        throw PackFormatException('unexpected EOF in frame data');
      }
      final take = min(left, _remaining);
      yield Uint8List.sublistView(_buf, _pos, _pos + take);
      _pos += take;
      left -= take;
    }
  }

  int get _remaining => _buf.length - _pos;

  /// Ensures at least [n] unread bytes are in the buffer.
  Future<bool> _ensure(int n) async {
    while (_remaining < n) {
      if (_sourceDone) return false;
      if (_pos > 0) {
        // compact consumed head
        _buf = Uint8List.sublistView(_buf, _pos);
        _pos = 0;
      }
      if (!await _it.moveNext()) {
        _sourceDone = true;
        break;
      }
      final chunk = _it.current;
      final merged = Uint8List(_buf.length + chunk.length);
      merged.setRange(0, _buf.length, _buf);
      merged.setRange(_buf.length, merged.length, chunk);
      _buf = merged;
    }
    return _remaining >= n;
  }
}

class PackFormatException implements Exception {
  PackFormatException(this.message);

  final String message;

  @override
  String toString() => 'PackFormatException: $message';
}
