import 'dart:io' show Platform;

/// Guards every VFS path access so that the resolved path stays inside the
/// shared root (交接文档 §7 生命线：路径穿越对策的单一实现点).
///
/// Usage contract with the server layer:
/// 1. Decode URL-escaping (`%2e%2e` etc.) **before** calling [resolve];
///    this class works on decoded strings only.
/// 2. After [resolve], resolve symlinks on the real file system
///    (`File(p).resolveSymbolicLinksSync()`) and re-run the containment
///    check — symlink escape (§7-2) cannot be ruled out on strings alone.
/// 3. Pass the re-checked path to the file backend.
///
/// Paths are represented with forward slashes internally; Windows
/// drive-letter roots (`C:/...`) and POSIX roots (`/...`) are both supported.
class PathGuard {
  /// Creates a guard for [root] (absolute path of the shared root).
  ///
  /// [caseSensitive] defaults to `true` on POSIX and `false` on Windows,
  /// matching the platform file systems (可行性报告 §9.4).
  PathGuard({required String root, bool? caseSensitive})
    : root = _normalizeRoot(root),
      caseSensitive = caseSensitive ?? Platform.isWindows {
    if (this.root.isEmpty) {
      throw ArgumentError.value(root, 'root', 'must not be empty');
    }
    _rootComparable = _comparable(this.root);
  }

  /// The normalized absolute shared root.
  final String root;

  /// Whether comparison against the root is case-sensitive.
  final bool caseSensitive;

  late final String _rootComparable;

  /// Resolves [requested] (relative or absolute, already URL-decoded) to a
  /// normalized absolute path guaranteed to be inside [root].
  ///
  /// Path forms accepted (R-013 virtual path semantics):
  /// - **Virtual**: `/sub/name` — the leading `/` addresses the *shared
  ///   root*, never the host filesystem. This is the canonical protocol form.
  /// - **Relative**: `sub/name` — anchored to the shared root.
  /// - **Legacy host-absolute**: a drive/POSIX-absolute path that already
  ///   lies inside the shared root (what earlier versions of LocalVfs
  ///   returned). Accepted for backward compatibility; anything absolute
  ///   *outside* the root is re-anchored as a virtual path (and thus either
  ///   404s or fails containment) — host layout never leaks.
  ///
  /// Throws [PathAccessException] for any escape attempt (`..`, UNC paths, …)
  /// and for empty input.
  String resolve(String requested) {
    if (requested.trim().isEmpty) {
      throw PathAccessException(requested, 'empty path');
    }
    var s = requested.replaceAll('\\', '/');
    if (s.startsWith('//?/')) s = s.substring(4); // Windows verbatim prefix
    if (s.replaceAll('/', '').isEmpty) {
      return root; // "/" or "//" etc. — the client asked for the root itself
    }
    final joined = _isLegacyHostAbsolute(s)
        ? s
        : '$root/${s.startsWith('/') ? s.substring(1) : s}';
    final posixAbs = joined.startsWith('/');

    final out = <String>[];
    for (final part in joined.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isEmpty || _isDriveComponent(out.last)) {
          throw PathAccessException(requested, 'escapes shared root');
        }
        out.removeLast();
        continue;
      }
      out.add(part);
    }
    var resolved = out.join('/');
    if (posixAbs) resolved = '/$resolved'; // rebuild the anchor split() ate
    if (resolved.isEmpty || resolved == '/') {
      throw PathAccessException(requested, 'escapes shared root');
    }
    if (_escapesRoot(resolved)) {
      throw PathAccessException(requested, 'escapes shared root');
    }
    return resolved;
  }

  bool _escapesRoot(String resolved) {
    final cmp = _comparable(resolved);
    if (cmp == _rootComparable) return false;
    return !cmp.startsWith('$_rootComparable/');
  }

  String _comparable(String p) => caseSensitive ? p : p.toLowerCase();

  /// Direct containment check for a **real** (already symlink-resolved)
  /// host path — used by the symlink re-check (§7-2). Unlike [resolve] this
  /// never re-anchors: a real path outside the root is outside, period.
  bool containsReal(String hostPath) {
    final cmp = _comparable(hostPath.replaceAll('\\', '/'));
    return cmp == _rootComparable || cmp.startsWith('$_rootComparable/');
  }

  /// True when [s] is a drive/POSIX-absolute path that already addresses
  /// inside the shared root (legacy form). Everything else — including any
  /// path outside the root — is treated as virtual/relative (R-013).
  bool _isLegacyHostAbsolute(String s) {
    final absolute = _hasDrive(s) || s.startsWith('/');
    if (!absolute) {
      return false;
    }
    final cmp = _comparable(s);
    return cmp == _rootComparable || cmp.startsWith('$_rootComparable/');
  }

  /// Maps a resolved host-absolute path back to the canonical virtual form
  /// (`/`= root, `/sub/name` inside). This is what the protocol returns so
  /// the host layout never leaks (R-013, §7).
  String toVirtual(String hostAbsolute) {
    var s = hostAbsolute.replaceAll('\\', '/');
    final cmp = _comparable(s);
    if (cmp == _rootComparable) {
      return '/';
    }
    if (cmp.startsWith('$_rootComparable/')) {
      final rel = s.substring(root.length);
      return rel.startsWith('/') ? rel : '/$rel';
    }
    // Outside the root should never happen (callers only pass resolved
    // paths); fall back to the raw string rather than throw at mapping time.
    return s.startsWith('/') ? s : '/$s';
  }

  /// Normalizes the trusted root: separators, dot segments, no trailing sep,
  /// POSIX leading slash / drive letter preserved.
  static String _normalizeRoot(String p) {
    var s = p.replaceAll('\\', '/');
    if (s.startsWith('//?/')) s = s.substring(4);
    final posixAbs = s.startsWith('/');
    final out = <String>[];
    for (final part in s.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty && !_isDriveComponent(out.last)) out.removeLast();
        continue;
      }
      out.add(part);
    }
    final joined = out.join('/');
    return posixAbs ? '/$joined' : joined;
  }

  static bool _hasDrive(String p) =>
      p.length >= 2 &&
      p.codeUnitAt(1) == 58 /* : */ &&
      _isLetter(p.codeUnitAt(0));

  static bool _isDriveComponent(String c) =>
      c.length == 2 && c.endsWith(':') && _isLetter(c.codeUnitAt(0));

  static bool _isLetter(int cp) =>
      (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122);
}

/// Thrown when a request path attempts to escape the shared root.
///
/// The message intentionally does not echo the resolved absolute path —
/// it is safe to surface to remote clients (§7: 信息泄露最小化).
class PathAccessException implements Exception {
  PathAccessException(this.requested, this.reason);

  final String requested;
  final String reason;

  @override
  String toString() => 'PathAccessException: $reason';
}
