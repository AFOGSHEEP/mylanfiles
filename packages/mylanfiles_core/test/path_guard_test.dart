import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:test/test.dart';

void main() {
  group('PathGuard (POSIX root, case-sensitive)', () {
    const root = '/storage/emulated/0';
    late PathGuard guard;
    setUp(() {
      guard = PathGuard(root: root, caseSensitive: true);
    });

    test('root normalizes', () {
      expect(
        PathGuard(root: '/storage/emulated/0/').root,
        '/storage/emulated/0',
      );
    });

    test('rejects empty', () {
      expect(() => guard.resolve(''), throwsA(isA<PathAccessException>()));
      expect(() => guard.resolve('   '), throwsA(isA<PathAccessException>()));
    });

    test('accepts relative path inside root', () {
      expect(guard.resolve('DCIM/a.jpg'), '$root/DCIM/a.jpg');
    });

    test('collapses dot segments and backslashes', () {
      expect(guard.resolve('./a/./b'), '$root/a/b');
      expect(guard.resolve('a\\..\\b'), '$root/b');
      expect(guard.resolve('a/'), '$root/a');
    });

    test('resolves to root itself for "."', () {
      expect(guard.resolve('.'), root);
    });

    test('rejects traversal beyond root', () {
      for (final p in ['../x', 'a/../../x', 'a/../../../x']) {
        expect(
          () => guard.resolve(p),
          throwsA(isA<PathAccessException>()),
          reason: p,
        );
      }
    });

    test(
      'absolute-looking paths are virtual: contained, never host-level (R-013)',
      () {
        // Leading "/" addresses the SHARED ROOT, not the host root — an
        // outside-absolute path becomes a path under the root.
        expect(guard.resolve('/etc/passwd'), '$root/etc/passwd');
        expect(guard.resolve('/data/app'), '$root/data/app');
      },
    );

    test('accepts absolute path inside root', () {
      expect(guard.resolve('$root/DCIM'), '$root/DCIM');
    });

    test('.. beyond the filesystem top is rejected', () {
      expect(() => guard.resolve('/../x'), throwsA(isA<PathAccessException>()));
    });
  });

  group('PathGuard (Windows root)', () {
    const root = 'C:/Users/gwen/share';
    late PathGuard guard;
    setUp(() {
      guard = PathGuard(root: root, caseSensitive: false);
    });

    test(
      'drive-absolute outside root is virtual-anchored, not host-level (R-013)',
      () {
        // Cannot address the host; lands inside the root (will simply 404).
        expect(guard.resolve('C:/Windows/system32'), startsWith('$root/'));
        expect(guard.containsReal('C:/Windows/system32'), isFalse);
      },
    );

    test('UNC-looking paths are contained (R-013)', () {
      // Cannot address the host; re-anchored under the shared root.
      expect(guard.resolve('//server/share/x'), startsWith('$root/'));
    });

    test(
      'verbatim prefix: outside re-anchored, inside root accepted (R-013)',
      () {
        // Outside the root: virtual-anchored (contained), no host access.
        expect(guard.resolve(r'\\?\C:\Windows'), startsWith('$root/'));
        // Stripped form already inside the root: legacy host-absolute accepted.
        expect(guard.resolve(r'\\?\C:\Users\gwen\share\a.txt'), '$root/a.txt');
      },
    );

    test('case-insensitive containment keeps original case', () {
      expect(
        guard.resolve(r'C:\USERS\GWEN\SHARE\Sub\File.txt'),
        'C:/USERS/GWEN/SHARE/Sub/File.txt',
      );
    });

    test(
      'case-sensitive mode: mismatched root case is virtual-anchored (R-013)',
      () {
        final strict = PathGuard(root: root, caseSensitive: true);
        // Case-mismatched host-absolute is not recognized as legacy, so it is
        // anchored as a virtual path — contained, cannot address outside.
        expect(strict.resolve('C:/Users/GWEN/share/x'), startsWith('$root/'));
      },
    );

    test('.. beyond drive letter is rejected', () {
      expect(
        () => guard.resolve('C:/../x'),
        throwsA(isA<PathAccessException>()),
      );
    });

    test('deeply nested traversal returning inside root is accepted', () {
      expect(guard.resolve('a/b/../../../share/c'), '$root/c');
    });

    test('R-013: virtual paths round-trip via toVirtual', () {
      final resolved = guard.resolve('/sub/name.txt');
      expect(resolved, '$root/sub/name.txt');
      expect(guard.toVirtual(resolved), '/sub/name.txt');
      expect(guard.toVirtual(root), '/');
      // Legacy host-absolute inside root maps to the same virtual path.
      expect(guard.toVirtual('$root/sub/name.txt'), '/sub/name.txt');
    });

    test('R-013: virtual path traversal still rejected', () {
      expect(
        () => guard.resolve('/../../etc/passwd'),
        throwsA(isA<PathAccessException>()),
      );
      expect(
        () => guard.resolve('/sub/../../outside'),
        throwsA(isA<PathAccessException>()),
      );
    });
  });

  test('error message does not leak resolved absolute paths', () {
    try {
      PathGuard(root: 'C:/Users/gwen/share').resolve('../secret.txt');
      fail('should throw');
    } on PathAccessException catch (e) {
      expect(e.toString(), isNot(contains('gwen')));
    }
  });
}
