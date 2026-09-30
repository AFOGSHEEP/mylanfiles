/// Minimal metadata set for a file-system entry (交接文档 §4.1 / §8 坑 5:
/// 最小元数据集 = size + mtime，其余不承诺).
class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.mtime,
  });

  factory FsEntry.fromMap(Map<dynamic, dynamic> m) => FsEntry(
    name: m['name'] as String,
    path: m['path'] as String,
    isDir: m['isDir'] as bool,
    size: (m['size'] as num).toInt(),
    mtime: m['mtime'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((m['mtime'] as num).toInt()),
  );

  /// File name only (no directory part).
  final String name;

  /// Absolute, normalized path inside the shared root.
  final String path;

  final bool isDir;

  /// Bytes; directories report 0.
  final int size;

  /// Last modified; null when the platform does not provide it.
  final DateTime? mtime;

  Map<String, Object?> toMap() => {
    'name': name,
    'path': path,
    'isDir': isDir,
    'size': size,
    'mtime': mtime?.millisecondsSinceEpoch,
  };

  @override
  String toString() => 'FsEntry($path${isDir ? '/' : ''}, $size B)';
}
