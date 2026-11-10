import 'dart:io';

import 'package:path/path.dart' as p;

class ArchiveBackup {
  const ArchiveBackup(this.path, this.modified, this.size);

  final String path;
  final DateTime modified;
  final int size;
}

Future<List<ArchiveBackup>> findArchiveBackups(String archive) async {
  final target = await File(archive).resolveSymbolicLinks();
  final prefix = '${p.basename(target)}.f7zip-backup-';
  final name = p.extension(target).toLowerCase() == '.7z'
      ? 'original.7z'
      : 'original.zip';
  final backups = <ArchiveBackup>[];
  await for (final entry in Directory(
    p.dirname(target),
  ).list(followLinks: false)) {
    if (entry is! Directory || !p.basename(entry.path).startsWith(prefix)) {
      continue;
    }
    final path = p.join(entry.path, name);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    final info = await File(path).stat();
    backups.add(ArchiveBackup(path, info.modified, info.size));
  }
  backups.sort((a, b) => b.modified.compareTo(a.modified));
  return backups;
}
