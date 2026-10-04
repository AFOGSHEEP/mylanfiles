import 'package:mylanfiles_core/mylanfiles_core.dart';

/// 相册/媒体快路径(交接文档 §4.1 media/list)。
///
/// V1 = 目录桶(bucket):按平台惯例目录(DCIM/Pictures/Screenshots/Movies/
/// Music/Download)聚合并按类型过滤、mtime 倒序分页——纯 Dart、跨平台、
/// 对 VFS 透明。原生 MediaStore 查询通道待真机性能数据再评估(risks.md)。
class MediaService {
  MediaService(this._vfs);

  final Vfs _vfs;

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

    final media = <FsEntry>[];
    await _walk(bucketEntry.path, 0, exts, since, media);
    media.sort(
      (a, b) => (b.mtime?.millisecondsSinceEpoch ?? 0).compareTo(
        a.mtime?.millisecondsSinceEpoch ?? 0,
      ),
    );

    final total = media.length;
    final page = media
        .skip(offset)
        .take(limit)
        .map((e) => e.toMap()..['kind'] = _kindOf(e.name))
        .toList();
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
