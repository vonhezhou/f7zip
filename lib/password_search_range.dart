import 'dart:convert';
import 'dart:math' as math;

class PasswordSearchRange {
  PasswordSearchRange._(
    this._words,
    this._alphabet, {
    this.minimum = 1,
    this.prefix = '',
    this.suffix = '',
    required this.count,
  });

  factory PasswordSearchRange.dictionary(String text) {
    if (utf8.encode(text).length > 4 * 1024 * 1024) {
      throw const FormatException('候选词表最多 4 MiB');
    }
    final words = text
        .split('\n')
        .map(
          (line) =>
              line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
        )
        .where((line) => line.isNotEmpty)
        .toSet()
        .toList();
    if (words.isEmpty || words.length > 10000) {
      throw const FormatException('请输入 1–10000 个候选，每行一个');
    }
    for (final word in words) {
      _validatePassword(word);
    }
    return PasswordSearchRange._(words, const [], count: words.length);
  }

  factory PasswordSearchRange.characters({
    required String alphabet,
    required int minimum,
    required int maximum,
    String prefix = '',
    String suffix = '',
  }) {
    final characters = alphabet.runes.toSet().map(String.fromCharCode).toList();
    if (characters.isEmpty ||
        characters.length > 64 ||
        alphabet.contains('\u0000')) {
      throw const FormatException('字符表需包含 1–64 个不同字符，不能包含空字符');
    }
    if (minimum < 1 || maximum < minimum || maximum > 8) {
      throw const FormatException('长度范围必须为 1–8，且下限不大于上限');
    }
    _validatePassword('$prefix$suffix');
    final characterBytes = characters
        .map((value) => utf8.encode(value).length)
        .reduce(math.max);
    if (utf8.encode('$prefix$suffix').length + characterBytes * maximum >
        4096) {
      throw const FormatException('候选长度超过 4096 UTF-8 字节');
    }
    var count = 0;
    var combinations = 1;
    for (var length = 1; length <= maximum; length++) {
      combinations *= characters.length;
      if (length >= minimum) count += combinations;
      if (count > 1000000) {
        throw const FormatException('搜索范围最多 1000000 个组合，请缩小范围');
      }
    }
    return PasswordSearchRange._(
      null,
      characters,
      minimum: minimum,
      prefix: prefix,
      suffix: suffix,
      count: count,
    );
  }

  final List<String>? _words;
  final List<String> _alphabet;
  final int minimum;
  final String prefix;
  final String suffix;
  final int count;

  String candidate(int index) {
    RangeError.checkValueInInterval(index, 0, count - 1, 'index');
    if (_words != null) return _words[index];
    var length = minimum;
    var combinations = _alphabet.length;
    for (var position = 1; position < minimum; position++) {
      combinations *= _alphabet.length;
    }
    while (index >= combinations) {
      index -= combinations;
      length++;
      combinations *= _alphabet.length;
    }
    final characters = List<String>.filled(length, '');
    for (var position = length - 1; position >= 0; position--) {
      characters[position] = _alphabet[index % _alphabet.length];
      index ~/= _alphabet.length;
    }
    return '$prefix${characters.join()}$suffix';
  }

  static void _validatePassword(String value) {
    if (value.contains('\u0000') || utf8.encode(value).length > 4096) {
      throw const FormatException('每个候选最多 4096 UTF-8 字节，不能包含空字符');
    }
  }
}
