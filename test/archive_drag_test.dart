import 'package:f7zip/archive_drag.dart';
import 'package:f7zip/archive_engine.dart';
import 'package:flutter_test/flutter_test.dart';

ArchiveEntry entry(
  int index,
  String path, {
  bool directory = false,
  bool encrypted = false,
}) => ArchiveEntry(
  index: index,
  path: path,
  size: 0,
  packed: 0,
  directory: directory,
  encrypted: encrypted,
  modified: 0,
);

void main() {
  test('父子选择只导出顶层，隐式目录包含完整索引与加密状态', () {
    final items = buildArchiveDragItems(
      [
        entry(0, 'folder/a.txt'),
        entry(1, 'folder/sub/b.txt', encrypted: true),
        entry(2, 'other'),
      ],
      {'folder', 'folder/sub/b.txt'},
    );
    expect(items.length, 1);
    expect(items.single.directory, isTrue);
    expect(items.single.encrypted, isTrue);
    expect(items.single.indices, [0, 1]);
    expect(items.single.path, 'folder');
  });
  test('同名根节点自动改名，保留输入自身的编号名称', () {
    final entries = [
      entry(0, 'a/file.txt'),
      entry(1, 'b/file.txt'),
      entry(2, 'c/file (2).txt'),
    ];
    final items = buildArchiveDragItems(
      entries,
      entries.map((item) => item.path).toSet(),
    );
    expect(items.map((item) => item.name), [
      'file.txt',
      'file (3).txt',
      'file (2).txt',
    ]);
    expect(items.map((item) => item.id), ['0', '1', '2']);
  });
  test('空目录支持拖出，失效选择与包内根节点忽略', () {
    final items = buildArchiveDragItems(
      [entry(0, 'empty/', directory: true)],
      {'empty', 'missing', ''},
    );
    expect(items.length, 1);
    expect(items.single.directory, isTrue);
    expect(items.single.indices, [0]);
    expect(items.single.toJson(), {
      'id': '0',
      'name': 'empty',
      'directory': true,
    });
  });
}
