/// Cross-platform file-name cleaning (交接文档 §8 坑 5).
///
/// Windows bans `< > : " / \ | ? *`, reserved device names and names ending
/// with dot/space; control characters are unsafe everywhere. The sanitizer
/// never throws — it produces the closest safe name so a remote sender never
/// breaks mid-transfer.
library;

const _illegalChars = r'<>:"/\|?*';
const _reserved = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

/// Returns [name] with every platform-illegal sequence replaced by `_`.
///
/// Empty / all-illegal input becomes `_unnamed_`. The extension after the
/// last dot is preserved where possible.
String sanitizeFilename(String name) {
  var s = name.trim();
  final buf = StringBuffer();
  for (final cp in s.codeUnits) {
    if (cp < 0x20 ||
        cp == 0x7f ||
        _illegalChars.contains(String.fromCharCode(cp))) {
      buf.write('_');
    } else {
      buf.writeCharCode(cp);
    }
  }
  s = buf.toString();
  if (s.isEmpty) return '_unnamed_';

  // Reserved device names, with or without extension (CON.txt is reserved too).
  final dot = s.indexOf('.');
  final stem = (dot >= 0 ? s.substring(0, dot) : s).toUpperCase();
  if (_reserved.contains(stem)) {
    s = '_$s';
  }

  // Windows: names must not END with a dot or space.
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  if (s.isEmpty) return '_unnamed_';
  return s;
}
