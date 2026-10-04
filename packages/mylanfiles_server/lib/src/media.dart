import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:convert' show utf8;

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;
import 'package:mylanfiles_core/mylanfiles_core.dart';

/// 相册/媒体快路径(交接文档 §4.1 media/list)。
///
/// V1 = 目录桶(bucket):按平台惯例目录(DCIM/Pictures/Screenshots/Movies/
/// Music/Download)聚合并按类型过滤、mtime 倒序分页——纯 Dart、跨平台、
/// 对 VFS 透明。原生 MediaStore 查询通道待真机性能数据再评估(risks.md)。
class MediaService {
  MediaService(this._vfs, {ThumbService? thumb}) : _thumb = thumb;

  final Vfs _vfs;

  /// 可选：给 image/video 条目签发缩略图 token（§4.1，防路径枚举）。
  final ThumbService? _thumb;

  final Map<String, _BucketCacheEntry> _bucketCache = {};

  static const knownBuckets = [
    'DCIM',
    'Pictures',
    'Screenshots',
    'Movies',
    'Video',
    'Music',
    'Download',
  ];

  static const imageExt = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'heic',
    'heif',
    'bmp',
    'avif',
    'dng',
  };
  static const videoExt = {
    'mp4',
    'mov',
    'mkv',
    'avi',
    'webm',
    '3gp',
    'm4v',
    'ts',
  };
  static const audioExt = {
    'mp3',
    'flac',
    'aac',
    'ogg',
    'wav',
    'm4a',
    'opus',
    'amr',
  };

  /// 列出存在的桶。桶名是根下的一级目录名(仅已知清单内的才返回),
  /// 天然免疫路径穿越——bucket 永远不会是任意路径。
  Future<List<Map<String, Object?>>> listBuckets() async {
    final out = <Map<String, Object?>>[];
    final entries = await _vfs.list('/');
    for (final name in knownBuckets) {
      final hit = entries.where(
        (e) => e.isDir && e.name.toLowerCase() == name.toLowerCase(),
      );
      if (hit.isNotEmpty) {
        out.add({'name': hit.first.name, 'path': hit.first.path});
      }
    }
    return out;
  }

  bool _bucketExists(List<FsEntry> rootEntries, String bucket) => rootEntries
      .any((e) => e.isDir && e.name.toLowerCase() == bucket.toLowerCase());

  /// 桶内媒体条目:深度 ≤3 walk + 类型/mtime 过滤 + mtime 倒序 + 分页。
  /// [type]: image|video|audio|any;[since]: mtime 毫秒下限。
  Future<Map<String, Object?>> listBucket(
    String bucket, {
    String type = 'any',
    int? since,
    int limit = 200,
    int offset = 0,
  }) async {
    final root = await _vfs.list('/');
    if (!_bucketExists(root, bucket)) {
      throw MediaBucketNotFoundException(bucket);
    }
    final bucketEntry = root.firstWhere(
      (e) => e.isDir && e.name.toLowerCase() == bucket.toLowerCase(),
    );

    final exts = switch (type) {
      'image' => imageExt,
      'video' => videoExt,
      'audio' => audioExt,
      _ => imageExt.union(videoExt).union(audioExt),
    };

    // 桶级缓存:目录未变(根 mtime)且 30s 内直接复用,避免大相册重复全walk。
    final cacheKey = bucketEntry.name.toLowerCase();
    final cached = _bucketCache[cacheKey];
    DateTime? rootMtime;
    try {
      rootMtime = (await _vfs.stat(bucketEntry.path)).mtime;
    } on Object {
      /* stat 失败则不缓存 */
    }
    if (cached != null &&
        rootMtime != null &&
        cached.rootMtime == rootMtime &&
        DateTime.now().difference(cached.fetchedAt) <
            const Duration(seconds: 30)) {
      return _pageFrom(cached.entries, bucketEntry, exts, since, offset, limit);
    }

    // 缓存与过滤解耦:walk 收全量,type/since 在分页时应用。
    final media = <FsEntry>[];
    await _walk(
      bucketEntry.path,
      0,
      imageExt.union(videoExt).union(audioExt),
      null,
      media,
    );

    if (rootMtime != null) {
      _bucketCache[cacheKey] = _BucketCacheEntry(
        entries: List.of(media),
        fetchedAt: DateTime.now(),
        rootMtime: rootMtime,
      );
    }
    return _pageFrom(media, bucketEntry, exts, since, offset, limit);
  }

  Map<String, Object?> _pageFrom(
    List<FsEntry> all,
    FsEntry bucketEntry,
    Set<String> exts,
    int? since,
    int offset,
    int limit,
  ) {
    final media = all.where((e) => _matches(e, exts, since)).toList()
      ..sort(
        (a, b) => (b.mtime?.millisecondsSinceEpoch ?? 0).compareTo(
          a.mtime?.millisecondsSinceEpoch ?? 0,
        ),
      );
    final total = media.length;
    final page = media.skip(offset).take(limit).map((e) {
      final m = e.toMap()..['kind'] = _kindOf(e.name);
      final kind = m['kind'] as String;
      if ((kind == 'image' || kind == 'video') && _thumb != null) {
        m['thumb'] = _thumb!.issueToken(e.path);
      }
      return m;
    }).toList();
    return {
      'bucket': bucketEntry.name,
      'path': bucketEntry.path,
      'total': total,
      'offset': offset,
      'limit': limit,
      'entries': page,
    };
  }

  Future<void> _walk(
    String dir,
    int depth,
    Set<String> exts,
    int? since,
    List<FsEntry> out,
  ) async {
    if (depth >= 3) {
      return;
    }
    final List<FsEntry> entries;
    try {
      entries = await _vfs.list(dir);
    } on Object {
      return; // 不可读目录(权限/竞争)直接跳过
    }
    for (final e in entries) {
      if (e.isDir) {
        await _walk(e.path, depth + 1, exts, since, out);
      } else if (_matches(e, exts, since)) {
        out.add(e);
      }
    }
  }

  bool _matches(FsEntry e, Set<String> exts, int? since) {
    final dot = e.name.lastIndexOf('.');
    if (dot < 0) {
      return false;
    }
    final ext = e.name.substring(dot + 1).toLowerCase();
    if (!exts.contains(ext)) {
      return false;
    }
    if (since != null && (e.mtime?.millisecondsSinceEpoch ?? 0) < since) {
      return false;
    }
    return true;
  }

  String _kindOf(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (imageExt.contains(ext)) return 'image';
    if (videoExt.contains(ext)) return 'video';
    if (audioExt.contains(ext)) return 'audio';
    return 'file';
  }
}

class MediaBucketNotFoundException implements Exception {
  MediaBucketNotFoundException(this.bucket);

  final String bucket;

  @override
  String toString() => 'MediaBucketNotFoundException: $bucket';
}

// ---- 缩略图(§4.1 /thumb):token 由列表/相册结果签发,防路径枚举 ----

/// 缩略图签发与渲染。
///
/// token 是服务端随机签发的一次性映射(会话内有效,LRU 上限),客户端无法
/// 从 token 构造或猜测路径——路径枚举被结构性排除。渲染结果按
/// (源 mtime, size) 落磁盘缓存,重开即命中。
class ThumbService {
  ThumbService(
    this._vfs, {
    this.cacheDir,
    this.maxTokens = 2000,
    this.maxSourceBytes = 30 << 20,
  });

  final Vfs _vfs;

  /// 磁盘缓存目录;null = 只在内存缓存(测试用)。
  final Directory? cacheDir;
  final int maxTokens;
  final int maxSourceBytes;

  final Map<String, String> _tokenToPath = {};
  final _rng = Random.secure();

  static const _sizes = {160, 320, 640};

  /// 为 [path] 签发缩略图 token(同路径重复签发返回同 token)。
  String issueToken(String path) {
    final existing = _tokenToPath.entries
        .where((e) => e.value == path)
        .map((e) => e.key)
        .firstOrNull;
    if (existing != null) {
      return existing;
    }
    if (_tokenToPath.length >= maxTokens) {
      _tokenToPath.remove(_tokenToPath.keys.first); // LRU 粗粒度驱逐
    }
    final token = List.generate(16, (_) => _rng.nextInt(256)).join();
    _tokenToPath[token] = path;
    return token;
  }

  /// 渲染缩略图。返回 (bytes, mime);找不到/不支持返回 null。
  Future<(Uint8List, String)?> render(String token, int size) async {
    final path = _tokenToPath[token];
    if (path == null) {
      return null;
    }
    final s = _sizes.contains(size) ? size : 320;

    // 磁盘缓存:mtime+size 变则失效。
    FsEntry st;
    try {
      st = await _vfs.stat(path);
    } on Object {
      return null;
    }
    if (st.isDir || st.size > maxSourceBytes) {
      return null;
    }
    if (cacheDir != null) {
      final key = crypto.sha256
          .convert(
            utf8.encode(
              '$path|${st.mtime?.millisecondsSinceEpoch}|${st.size}|$s',
            ),
          )
          .toString();
      final cached = File('${cacheDir!.path}/$key.jpg');
      if (await cached.exists()) {
        return (await cached.readAsBytes(), 'image/jpeg');
      }
      final rendered = await _decodeResize(path, s);
      if (rendered != null) {
        try {
          if (!cacheDir!.existsSync()) {
            cacheDir!.createSync(recursive: true);
          }
          await cached.writeAsBytes(rendered, flush: true);
        } on Object {
          /* 缓存写失败不致命 */
        }
        return (rendered, 'image/jpeg');
      }
      return null;
    }
    final rendered = await _decodeResize(path, s);
    return rendered == null ? null : (rendered, 'image/jpeg');
  }

  Future<Uint8List?> _decodeResize(String path, int size) async {
    final data = await _vfs
        .read(path)
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
    img.Image? decoded;
    try {
      decoded = img.decodeImage(Uint8List.fromList(data));
    } on Object {
      return null;
    }
    if (decoded == null) {
      return null; // HEIC 等暂不支持:客户端显示占位
    }
    final thumb = img.copyResize(
      decoded,
      width: size,
      height: size,
      maintainAspect: true,
    );
    return Uint8List.fromList(img.encodeJpg(thumb, quality: 78));
  }
}

/// 清理超龄断点文件(`.part`/`.mlfpart`):上传输half与下载half的孤儿。
/// 返回删除数;walk 深度受限,避免全盘扫(手机端共享根可能极大)。
Future<int> cleanupStaleParts(
  Vfs vfs, {
  Duration age = const Duration(days: 7),
  int maxDepth = 3,
}) async {
  var removed = 0;
  Future<void> walk(String dir, int depth) async {
    if (depth >= maxDepth) {
      return;
    }
    final List<FsEntry> entries;
    try {
      entries = await vfs.list(dir);
    } on Object {
      return;
    }
    for (final e in entries) {
      if (e.isDir) {
        await walk(e.path, depth + 1);
      } else if ((e.name.endsWith('.part') || e.name.endsWith('.mlfpart')) &&
          e.mtime != null &&
          DateTime.now().difference(e.mtime!) > age) {
        try {
          await vfs.delete(e.path);
          removed++;
        } on Object {
          /* 竞争删除失败忽略 */
        }
      }
    }
  }

  await walk('/', 0);
  return removed;
}

class _BucketCacheEntry {
  _BucketCacheEntry({
    required this.entries,
    required this.fetchedAt,
    required this.rootMtime,
  });

  final List<FsEntry> entries;
  final DateTime fetchedAt;
  final DateTime rootMtime;
}
