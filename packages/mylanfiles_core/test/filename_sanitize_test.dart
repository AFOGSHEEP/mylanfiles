import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:test/test.dart';

void main() {
  test('replaces Windows-illegal characters', () {
    expect(sanitizeFilename(r'a<b>c:d"e|f?g*h'), 'a_b_c_d_e_f_g_h');
    expect(sanitizeFilename('name?.txt'), 'name_.txt');
  });

  test('replaces control characters', () {
    expect(sanitizeFilename('a\x00b\x1fc'), 'a_b_c');
  });

  test('prefixes reserved device names (with or without extension)', () {
    expect(sanitizeFilename('CON'), '_CON');
    expect(sanitizeFilename('con.txt'), '_con.txt');
    expect(sanitizeFilename('LPT9.pdf'), '_LPT9.pdf');
    expect(sanitizeFilename('content.txt'), 'content.txt'); // not reserved
  });

  test('strips trailing dots and spaces (Windows)', () {
    expect(sanitizeFilename('file.txt...'), 'file.txt');
    expect(sanitizeFilename('name  '), 'name');
    expect(sanitizeFilename('...'), '_unnamed_');
  });

  test('empty becomes _unnamed_', () {
    expect(sanitizeFilename(''), '_unnamed_');
  });

  test('keeps CJK and spaces', () {
    expect(sanitizeFilename('旅行照片 2026.jpg'), '旅行照片 2026.jpg');
  });
}
