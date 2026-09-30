import '../model/fs_entry.dart';

/// Virtual file system over the shared root.
///
/// Contract (交接文档 §4.1 / §7):
/// - Every path argument goes through [PathGuard] containment before IO;
///   escapes throw [PathAccessException] (maps to HTTP 403).
/// - [read]/[write] stream — an entire file is never held in memory.
/// - Relative paths are resolved against the root; absolute paths inside the
///   root are accepted.
abstract interface class Vfs {
  /// The normalized absolute shared root.
  String get root;

  /// Lists a directory. [path] defaults to the root.
  Future<List<FsEntry>> list([String path = '/']);

  /// Metadata of a single entry (file or directory).
  Future<FsEntry> stat(String path);

  /// Streams [length] bytes (or to EOF when null) starting at [offset].
  /// Throws [VfsNotFoundException] when missing, [VfsIsDirException] for dirs.
  Stream<List<int>> read(String path, {int offset = 0, int? length});

  /// Writes [body] at [offset]; `offset == 0` truncates first.
  /// `offset > 0` requires the file to exist and is the resume path —
  /// bytes shorter than [offset] are truncated to [offset] before writing.
  /// Returns the resulting file size in bytes.
  Future<int> write(String path, Stream<List<int>> body, {int offset = 0});

  Future<void> mkdir(String path, {bool recursive = false});

  Future<void> delete(String path, {bool recursive = false});

  /// Renames the entry at [path] to [newName] (a bare file name, sanitized
  /// with [sanitizeFilename] semantics by implementations).
  Future<void> rename(String path, String newName);

  /// Copies the entry into directory [targetDir] (inside the same root).
  Future<void> copy(String path, String targetDir);

  /// Moves the entry into directory [targetDir] (inside the same root).
  Future<void> move(String path, String targetDir);
}

/// File or directory does not exist (HTTP 404).
class VfsNotFoundException implements Exception {
  VfsNotFoundException(this.path);

  final String path;

  @override
  String toString() => 'VfsNotFoundException: $path';
}

/// A directory was used where a file is required (HTTP 409).
class VfsIsDirException implements Exception {
  VfsIsDirException(this.path);

  final String path;

  @override
  String toString() => 'VfsIsDirException: $path';
}

/// Target exists and the caller did not allow overwriting (HTTP 409).
class VfsConflictException implements Exception {
  VfsConflictException(this.path);

  final String path;

  @override
  String toString() => 'VfsConflictException: $path';
}
