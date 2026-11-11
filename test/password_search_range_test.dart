import 'package:f7zip/password_search_range.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('词表去重并保留有意的空格与 Unicode，兼容 CRLF', () {
    final range = PasswordSearchRange.dictionary(
      ' wrong \r\n中文😀\n wrong \n\n',
    );
    expect(range.count, 2);
    expect(range.candidate(0), ' wrong ');
    expect(range.candidate(1), '中文😀');
    expect(() => range.candidate(-1), throwsRangeError);
    expect(() => range.candidate(2), throwsRangeError);
  });
  test('字符范围按长度和字符顺序枚举，前后缀不占搜索长度', () {
    final range = PasswordSearchRange.characters(
      alphabet: 'aba',
      minimum: 1,
      maximum: 3,
      prefix: 'known-',
      suffix: '!',
    );
    expect(range.count, 14);
    expect(List.generate(range.count, range.candidate), [
      'known-a!',
      'known-b!',
      'known-aa!',
      'known-ab!',
      'known-ba!',
      'known-bb!',
      'known-aaa!',
      'known-aab!',
      'known-aba!',
      'known-abb!',
      'known-baa!',
      'known-bab!',
      'known-bba!',
      'known-bbb!',
    ]);
  });
  test('起始长度和 Unicode 字符按码点处理，可从任意索引继续', () {
    final range = PasswordSearchRange.characters(
      alphabet: '😀中',
      minimum: 2,
      maximum: 2,
    );
    expect(range.count, 4);
    expect(range.candidate(2), '中😀');
    expect(range.candidate(3), '中中');
    final single = PasswordSearchRange.characters(
      alphabet: 'x',
      minimum: 2,
      maximum: 4,
    );
    expect(List.generate(single.count, single.candidate), [
      'xx',
      'xxx',
      'xxxx',
    ]);
  });
  test('组合、长度、字符及 UTF-8 字节预算拒绝超范围', () {
    for (final text in [
      '',
      'bad\u0000password',
      '😀' * 1025,
      'x\n' * 2100000,
    ]) {
      expect(() => PasswordSearchRange.dictionary(text), throwsFormatException);
    }
    expect(
      () => PasswordSearchRange.dictionary(
        List.generate(10001, (i) => '$i').join('\n'),
      ),
      throwsFormatException,
    );
    for (final alphabet in [
      '',
      '\u0000',
      List.generate(65, (i) => String.fromCharCode(i + 32)).join(),
    ]) {
      expect(
        () => PasswordSearchRange.characters(
          alphabet: alphabet,
          minimum: 1,
          maximum: 1,
        ),
        throwsFormatException,
      );
    }
    for (final lengths in [(0, 1), (2, 1), (1, 9), (7, 7)]) {
      expect(
        () => PasswordSearchRange.characters(
          alphabet: '0123456789',
          minimum: lengths.$1,
          maximum: lengths.$2,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => PasswordSearchRange.characters(
        alphabet: '😀',
        minimum: 1,
        maximum: 8,
        prefix: 'a' * 4090,
      ),
      throwsFormatException,
    );
  });
}
