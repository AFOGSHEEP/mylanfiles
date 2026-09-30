import 'dart:io';

import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late LocalVfs vfs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mlf_vfs_test');
    vfs = LocalVfs(root: tmp.path);
    await File('${tmp.path}/hello.txt').writeAsString('hello world');
    await Directory('${tmp.path}/sub').create();
    await File('${tmp.path}/sub/inner.txt').writeAsString('inner');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('list', () {
    test('lists root with dirs first, sorted', () async {
      final entries = await vfs.list();
      expect(entries.map((e) => e.name), ['sub', 'hello.txt']);
      expect(entries.first.isDir, isTrue);
    });

    test('lists subdirectory and reports sizes', () async {
      final entries = await vfs.list('sub');
      expect(entries.single.name, 'inner.txt');
      expect(entries.single.size, 'inner'.length);
    });

    test('traversal via list is rejected', () {
      expect(() => vfs.list('../'), throwsA(isA<PathAccessException>()));
    });
  });

  group('read / write', () {
    test('round-trips a file', () async {
      final bytes = await vfs.read('hello.txt').expand((c) => c).toList();
      expect(String.fromCharCodes(bytes), 'hello world');
    });

    test('reads with offset and length', () async {
      final bytes = await vfs
          .read('hello.txt', offset: 6, length: 5)
          .expand((c) => c)
          .toList();
      expect(String.fromCharCodes(bytes), 'world');
    });

    test('write truncates at offset 0 and resumes at offset>0', () async {
      await vfs.write('hello.txt', Stream.value('HEJ'.codeUnits));
      expect(await File('${tmp.path}/hello.txt').readAsString(), 'HEJ');

      await vfs.write('hello.txt', Stream.value('!!'.codeUnits), offset: 3);
      expect(await File('${tmp.path}/hello.txt').readAsString(), 'HEJ!!');
    });

    test('write refuses directories and outside-root paths', () async {
      expect(
        () => vfs.write('sub', Stream.value('x'.codeUnits)),
        throwsA(isA<VfsIsDirException>()),
      );
      expect(
        () => vfs.write('../evil.txt', Stream.value('x'.codeUnits)),
        throwsA(isA<PathAccessException>()),
      );
    });

    test('read missing file throws VfsNotFoundException', () async {
      await expectLater(
        vfs.read('nope.txt').toList(),
        throwsA(isA<VfsNotFoundException>()),
      );
    });
  });

  group('ops', () {
    test('mkdir / rename / delete', () async {
      await vfs.mkdir('newdir');
      expect(Directory('${tmp.path}/newdir').existsSync(), isTrue);

      await vfs.rename('newdir', 'renamed');
      expect(Directory('${tmp.path}/renamed').existsSync(), isTrue);

      await vfs.delete('renamed');
      expect(Directory('${tmp.path}/renamed').existsSync(), isFalse);
    });

    test('mkdir recursive creates level by level inside root', () async {
      await vfs.mkdir('a/b/c', recursive: true);
      expect(Directory('${tmp.path}/a/b/c').existsSync(), isTrue);
    });

    test('rename sanitizes hostile names', () async {
      await vfs.rename('hello.txt', 'CON');
      expect(File('${tmp.path}/_CON').existsSync(), isTrue);
    });

    test('rename refuses to overwrite', () {
      expect(
        () => vfs.rename('hello.txt', 'sub'),
        throwsA(isA<VfsConflictException>()),
      );
    });

    test('copy and move within root', () async {
      await vfs.copy('hello.txt', 'sub');
      expect(
        File('${tmp.path}/sub/hello.txt').readAsStringSync(),
        'hello world',
      );

      await vfs.move('sub/inner.txt', '.');
      expect(File('${tmp.path}/inner.txt').existsSync(), isTrue);
    });

    test('copy refuses overwrite', () {
      expect(
        () => vfs.copy('hello.txt', '.'),
        throwsA(isA<VfsConflictException>()),
      );
    });
  });

  group('symlink escape (§7-2)', () {
    test('read through symlink pointing outside is rejected', () async {
      // Second temp dir OUTSIDE the shared root as the escape target.
      final outside = await Directory.systemTemp.createTemp('mlf_outside');
      try {
        final target = File('${outside.path}/secret.txt');
        await target.writeAsString('outside');
        try {
          await Link('${tmp.path}/evil').create(target.path);
        } on FileSystemException {
          return; // symlink privilege denied on this machine
        }
        await expectLater(
          vfs.read('evil').toList(),
          throwsA(isA<PathAccessException>()),
        );
      } finally {
        await outside.delete(recursive: true);
      }
    });
  });
}
