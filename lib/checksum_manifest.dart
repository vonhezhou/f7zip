import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class ChecksumEntry {
  const ChecksumEntry(this.name, this.algorithm, this.expected);
  final String name;
  final String algorithm;
  final String expected;
}

List<ChecksumEntry> parseChecksumManifest(String content) {
  final entries = <ChecksumEntry>[];
  final seen = <String>{};
  for (var line in const LineSplitter().convert(
    content.replaceFirst(RegExp(r'^\uFEFF'), ''),
  )) {
    if (line.trim().isEmpty || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }
    final escaped = line.startsWith('\\');
    if (escaped) line = line.substring(1);
    final standard = RegExp(
      r'^([a-fA-F0-9]{64}|[a-fA-F0-9]{16}|[a-fA-F0-9]{8}) [ *](.+)$',
    ).firstMatch(line);
    final sfv = standard == null && !escaped
        ? RegExp(r'^(.+) ([a-fA-F0-9]{8})$').firstMatch(line)
        : null;
    if (standard == null && sfv == null) {
      throw const FormatException('无法识别清单行，支持 SHA-256、CRC32 与 CRC64/XZ 清单');
    }
    var name = standard?.group(2) ?? sfv!.group(1)!;
    final hash = standard?.group(1) ?? sfv!.group(2)!;
    if (escaped) {
      final decoded = StringBuffer();
      for (var index = 0; index < name.length; index++) {
        if (name[index] != '\\') {
          decoded.write(name[index]);
          continue;
        }
        if (++index == name.length) throw const FormatException('清单文件名转义不完整');
        decoded.write(switch (name[index]) {
          'n' => '\n',
          'r' => '\r',
          '\\' => '\\',
          _ => throw const FormatException('清单文件名包含未知转义'),
        });
      }
      name = decoded.toString();
    }
    if (name.contains('\x00') ||
        p.isAbsolute(name) ||
        RegExp(r'^[A-Za-z]:').hasMatch(name) ||
        p.split(name).contains('..') ||
        p.normalize(name) == '.') {
      throw const FormatException('清单文件名必须位于清单目录内');
    }
    name = p.normalize(name);
    final algorithm = switch (hash.length) {
      64 => 'sha256',
      16 => 'crc64',
      _ => 'crc32',
    };
    if (!seen.add('$algorithm\x00$name')) {
      throw const FormatException('清单包含重复文件和算法');
    }
    entries.add(ChecksumEntry(name, algorithm, hash.toUpperCase()));
    if (entries.length > 10000) throw const FormatException('校验清单最多支持 10000 项');
  }
  if (entries.isEmpty) throw const FormatException('校验清单为空');
  return entries;
}

Future<(String, List<ChecksumEntry>)> readChecksumManifest(String path) async {
  final file = File(path);
  if (await file.length() > 4 * 1024 * 1024) {
    throw const FormatException('校验清单超过 4 MiB');
  }
  final bytes = await file
      .openRead(0, 4 * 1024 * 1024 + 1)
      .fold<List<int>>(<int>[], (collected, chunk) => collected..addAll(chunk));
  if (bytes.length > 4 * 1024 * 1024) {
    throw const FormatException('校验清单超过 4 MiB');
  }
  final entries = parseChecksumManifest(utf8.decode(bytes));
  final directory = p.dirname(await file.resolveSymbolicLinks());
  for (final entry in entries) {
    // 禁止通过清单目录内的链接父级访问目录外文件。
    var parent = directory;
    for (final component in p.split(entry.name)) {
      parent = p.join(parent, component);
      if (await FileSystemEntity.type(parent, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('清单目标不能使用符号链接');
      }
    }
  }
  return (directory, entries);
}
