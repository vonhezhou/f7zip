import 'package:path/path.dart' as p;

import 'archive_engine.dart';

class ArchiveDragItem {
  const ArchiveDragItem({
    required this.id,
    required this.path,
    required this.name,
    required this.directory,
    required this.encrypted,
    required this.indices,
  });
  final String id;
  final String path;
  final String name;
  final bool directory;
  final bool encrypted;
  final List<int> indices;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'directory': directory,
  };
}

List<ArchiveDragItem> buildArchiveDragItems(
  List<ArchiveEntry> entries,
  Set<String> selection,
) {
  final roots = selection.where((path) {
    if (path.isEmpty) return false;
    var parent = p.posix.dirname(path);
    while (parent != '.' && parent.isNotEmpty) {
      if (selection.contains(parent)) return false;
      parent = p.posix.dirname(parent);
    }
    return true;
  }).toList()..sort();
  final reserved = roots.map(p.posix.basename).toSet();
  final used = <String>{};
  final items = <ArchiveDragItem>[];
  for (final path in roots) {
    final included = entries
        .where((entry) => entry.isSelectedBy({path}))
        .toList();
    if (included.isEmpty) continue;
    final directory = included.any(
      (entry) => entry.directory || entry.normalizedPath != path,
    );
    final original = p.posix.basename(path);
    var name = original;
    final extension = directory ? '' : p.posix.extension(original);
    final stem = directory
        ? original
        : p.posix.basenameWithoutExtension(original);
    var suffix = 2;
    while (used.contains(name)) {
      do {
        name = '$stem (${suffix++})$extension';
      } while (reserved.contains(name));
    }
    used.add(name);
    items.add(
      ArchiveDragItem(
        id: '${items.length}',
        path: path,
        name: name,
        directory: directory,
        encrypted: included.any((entry) => entry.encrypted),
        indices: List.unmodifiable(included.map((entry) => entry.index)),
      ),
    );
  }
  return items;
}
