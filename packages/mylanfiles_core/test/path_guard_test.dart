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

    test('rejects absolute paths outside root (POSIX)', () {
      expect(
        () => guard.resolve('/etc/passwd'),
        throwsA(isA<PathAccessException>()),
      );
      expect(
        () => guard.resolve('/data/app'),
        throwsA(isA<PathAccessException>()),
      );
    });

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

    test('rejects drive-absolute escape', () {
      expect(
        () => guard.resolve('C:/Windows/system32'),
        throwsA(isA<PathAccessException>()),
      );
    });

    test('rejects UNC path injection', () {
      expect(
        () => guard.resolve(r'\\server\share\x'),
        throwsA(isA<PathAccessException>()),
      );
    });

    test('rejects verbatim-prefix escape, accepts stripped within root', () {
      expect(
        () => guard.resolve(r'\\?\C:\Windows'),
        throwsA(isA<PathAccessException>()),
      );
      expect(guard.resolve(r'\\?\C:\Users\gwen\share\a.txt'), '$root/a.txt');
    });

    test('case-insensitive containment keeps original case', () {
      expect(
        guard.resolve(r'C:\USERS\GWEN\SHARE\Sub\File.txt'),
        'C:/USERS/GWEN/SHARE/Sub/File.txt',
      );
    });

    test('case-sensitive mode rejects case mismatch', () {
      final strict = PathGuard(root: root, caseSensitive: true);
      expect(
        () => strict.resolve('C:/Users/GWEN/share/x'),
        throwsA(isA<PathAccessException>()),
      );
    });

    test('.. beyond drive letter is rejected', () {
      expect(
        () => guard.resolve('C:/../x'),
        throwsA(isA<PathAccessException>()),
      );
    });

    test('deeply nested traversal returning inside root is accepted', () {
      expect(guard.resolve('a/b/../../../share/c'), '$root/c');
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
