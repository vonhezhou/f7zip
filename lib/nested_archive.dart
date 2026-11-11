import 'package:path/path.dart' as p;

const nestedArchiveLimit = 256 * 1024 * 1024;
const nestedArchiveDepth = 8;

bool isNestedArchive(String path) => const {
  '.zip',
  '.zipx',
  '.exe',
  '.7z',
  '.rar',
  '.tar',
  '.gz',
  '.xz',
  '.bz2',
  '.tgz',
  '.tbz',
  '.tbz2',
  '.txz',
  '.iso',
  '.cab',
  '.wim',
}.contains(p.posix.extension(path).toLowerCase());

class ArchiveParent {
  ArchiveParent({
    required this.archive,
    required this.password,
    required this.codePage,
    required this.folder,
    required this.query,
    required this.selection,
    required this.navigation,
    required this.navigationIndex,
    required this.directory,
  });

  final String archive;
  final String password;
  final int codePage;
  final String folder;
  final String query;
  final Set<String> selection;
  final List<String> navigation;
  final int navigationIndex;
  final String directory;
}
