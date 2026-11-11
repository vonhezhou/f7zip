import 'package:f7zip/nested_archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('子包识别限定独立归档类型并设定容量与层数上限', () {
    for (final path in [
      'a.ZIP',
      'a.ZIPX',
      'a.exe',
      'a.wim',
      'folder/a.7z',
      'a.tar.gz',
      'a.TXZ',
      'a.rar',
    ]) {
      expect(isNestedArchive(path), isTrue);
    }
    for (final path in ['a.txt', 'a.zip.001', 'a.z01', 'a.r00', 'README']) {
      expect(isNestedArchive(path), isFalse);
    }
    expect(nestedArchiveLimit, 256 * 1024 * 1024);
    expect(nestedArchiveDepth, 8);
  });
}
