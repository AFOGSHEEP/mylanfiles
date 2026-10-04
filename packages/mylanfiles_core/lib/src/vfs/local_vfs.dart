import 'dart:io';

import '../filename_sanitize.dart';
import '../model/fs_entry.dart';
import '../path_guard.dart';
import 'vfs.dart';

/// [Vfs] over the local file system, confined to a shared root.
///
/// Every path-handling entry point re-checks containment with [PathGuard];
/// for the operations that follow links, the real path is resolved via
/// `resolveSymbolicLinksSync` and re-checked (§7-2 symlink escape).
class LocalVfs implements Vfs {
  LocalVfs({required String root, bool? caseSensitive})
    : _guard = PathGuard(root: root, caseSensitive: caseSensitive);

  final PathGuard _guard;

  @override
  String get root => _guard.root;

  @override
  Future<List<FsEntry>> list([String path = '/']) async {
    final dir = Directory(_guard.resolve(path));
    if (!dir.existsSync()) {
      throw VfsNotFoundException(path);
    }
    final entities = await dir.list(followLinks: false).toList();
    final entries = <FsEntry>[];
    for (final e in entities) {
      var size = 0;
      DateTime? mtime;
      try {
        final stat = FileStat.statSync(e.path);
        mtime = stat.modified;
        if (FileSystemEntity.typeSync(e.path, followLinks: true) !=
            FileSystemEntityType.directory) {
          size = stat.size;
        }
      } on FileSystemException {
        // A file vanishing mid-listing must not kill the listing.
      }
      entries.add(
        FsEntry(
          name: _basename(e.path),
          // Virtual path (R-013): `/` = root; host layout never leaves the VFS.
          path: _guard.toVirtual(e.path),
          isDir:
              FileSystemEntity.typeSync(e.path, followLinks: true) ==
              FileSystemEntityType.directory,
          size: size,
          mtime: mtime,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<FsEntry> stat(String path) async {
    final p = _guard.resolve(path);
    final real = _resolveExistingSync(p);
    final t = FileSystemEntity.typeSync(real, followLinks: true);
    final stat = FileStat.statSync(real);
    return FsEntry(
      name: _basename(real),
      path: _guard.toVirtual(real),
      isDir: t == FileSystemEntityType.directory,
      size: t == FileSystemEntityType.directory ? 0 : stat.size,
      mtime: stat.modified,
    );
  }

  @override
  Stream<List<int>> read(String path, {int offset = 0, int? length}) async* {
    final p = _resolveExistingSync(_guard.resolve(path));
    if (FileSystemEntity.typeSync(p, followLinks: true) ==
        FileSystemEntityType.directory) {
      throw VfsIsDirException(path);
    }
    final end = length == null ? null : offset + length;
    yield* File(p).openRead(offset, end);
  }

  @override
  Future<int> write(
    String path,
    Stream<List<int>> body, {
    int offset = 0,
  }) async {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must be >= 0');
    }
    final p = _guard.resolve(path);
    if (FileSystemEntity.typeSync(p, followLinks: true) ==
        FileSystemEntityType.directory) {
      throw VfsIsDirException(path);
    }
    // 契约：offset>0 是续传路径，要求目标已存在（对抗轮3：此前隐式零扩展建文件）。
    if (offset > 0 && !FileSystemEntity.isFileSync(p)) {
      throw VfsNotFoundException(path);
    }
    // Resume semantics: append mode writes at current EOF, so
    // truncate(offset) keeps [0, offset) and puts the EOF there.
    final raf = await File(p).open(mode: FileMode.append);
    try {
      await raf.truncate(offset);
      var written = 0;
      await for (final chunk in body) {
        await raf.writeFrom(chunk);
        written += chunk.length;
      }
      return offset + written;
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {
    final p = _guard.resolve(path);
    if (FileSystemEntity.typeSync(p, followLinks: true) !=
        FileSystemEntityType.notFound) {
      throw VfsConflictException(path);
    }
    if (recursive) {
      // Stepwise creation keeps every intermediate level inside the root.
      var cur = _guard.root;
      final rel = p.length > cur.length ? p.substring(cur.length + 1) : '';
      for (final seg in rel.split('/').where((s) => s.isNotEmpty)) {
        cur = '$cur/$seg';
        if (FileSystemEntity.typeSync(cur) == FileSystemEntityType.notFound) {
          await Directory(cur).create();
        }
      }
      return;
    }
    await Directory(p).create();
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final p = _resolveExistingSync(_guard.resolve(path));
    if (FileSystemEntity.typeSync(p, followLinks: true) ==
        FileSystemEntityType.directory) {
      await Directory(p).delete(recursive: recursive);
    } else {
      await File(p).delete();
    }
  }

  @override
  Future<void> rename(String path, String newName) async {
    final safe = sanitizeFilename(newName);
    if (safe.isEmpty) {
      throw ArgumentError.value(newName, 'newName', 'empty after sanitize');
    }
    final oldPath = _guard.resolve(path);
    final parent = oldPath.substring(0, oldPath.lastIndexOf('/'));
    final newPath = _guard.resolve('$parent/$safe');
    if (FileSystemEntity.typeSync(newPath, followLinks: true) !=
        FileSystemEntityType.notFound) {
      throw VfsConflictException(newName);
    }
    await _renameEntity(_resolveExistingSync(oldPath), newPath);
  }

  @override
  Future<void> copy(String path, String targetDir) async {
    final src = _resolveExistingSync(_guard.resolve(path));
    final dstDir = _guard.resolve(targetDir);
    final dst = '$dstDir/${_basename(src)}';
    if (FileSystemEntity.typeSync(dst, followLinks: true) !=
        FileSystemEntityType.notFound) {
      throw VfsConflictException(dst);
    }
    await _copyEntity(src, dst);
  }

  @override
  Future<void> move(String path, String targetDir) async {
    final src = _resolveExistingSync(_guard.resolve(path));
    final dstDir = _guard.resolve(targetDir);
    final dst = '$dstDir/${_basename(src)}';
    if (FileSystemEntity.typeSync(dst, followLinks: true) !=
        FileSystemEntityType.notFound) {
      throw VfsConflictException(dst);
    }
    await _renameEntity(src, dst);
  }

  Future<void> _copyEntity(String src, String dst) async {
    if (FileSystemEntity.typeSync(src, followLinks: true) ==
        FileSystemEntityType.directory) {
      await Directory(dst).create();
      await for (final e in Directory(src).list(followLinks: false)) {
        // NB: copying a directory into its own subtree is rejected upstream
        // by the conflict check on the first level only; deep self-copy is
        // the caller's responsibility (P1: add ancestor check).
        await _copyEntity(e.path, '$dst/${_basename(e.path)}');
      }
    } else {
      await File(src).copy(dst);
    }
  }

  Future<void> _renameEntity(String src, String dst) async {
    if (FileSystemEntity.typeSync(src, followLinks: true) ==
        FileSystemEntityType.directory) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
  }

  /// Resolves symlinks to the real path and re-checks containment (§7-2).
  String _resolveExistingSync(String p) {
    final t = FileSystemEntity.typeSync(p);
    if (t == FileSystemEntityType.notFound) {
      throw VfsNotFoundException(p);
    }
    final real = _entityFor(
      t,
      p,
    ).resolveSymbolicLinksSync().replaceAll('\\', '/');
    if (!_guard.containsReal(real)) {
      throw PathAccessException(p, 'symlink escapes shared root');
    }
    return real;
  }

  FileSystemEntity _entityFor(FileSystemEntityType t, String p) =>
      t == FileSystemEntityType.directory ? Directory(p) : File(p);

  String _basename(String osPath) =>
      osPath.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).last;
}
