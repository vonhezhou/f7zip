import 'package:path/path.dart' as p;

enum ArchivePreviewKind {
  text,
  image,
  pdf,
  audio,
  video;

  int get outputLimit => this == text ? 4 * 1024 * 1024 : 256 * 1024 * 1024;

  String outputName(String path) => this == text
      ? 'content.txt'
      : 'content${p.posix.extension(path).toLowerCase()}';

  static ArchivePreviewKind? forPath(String path) {
    final name = p.posix.basename(path).toLowerCase();
    final extension = p.posix.extension(name).replaceFirst('.', '');
    if (const {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'bmp',
      'tif',
      'tiff',
      'heic',
      'heif',
      'ico',
    }.contains(extension)) {
      return image;
    }
    if (extension == 'pdf') return pdf;
    if (const {
      'mp3',
      'm4a',
      'aac',
      'wav',
      'aif',
      'aiff',
      'caf',
    }.contains(extension)) {
      return audio;
    }
    if (const {'mp4', 'mov', 'm4v'}.contains(extension)) return video;
    if (const {
          'txt',
          'md',
          'markdown',
          'json',
          'log',
          'csv',
          'tsv',
          'yaml',
          'yml',
          'toml',
          'ini',
          'conf',
          'config',
          'xml',
          'plist',
          'sh',
          'py',
          'dart',
          'js',
          'ts',
          'java',
          'kt',
          'swift',
          'c',
          'cpp',
          'h',
          'hpp',
          'rs',
          'go',
          'css',
          'sql',
          'properties',
        }.contains(extension) ||
        const {
          'readme',
          'license',
          'notice',
          'makefile',
          'dockerfile',
          '.env',
          '.gitignore',
          '.gitattributes',
          '.editorconfig',
        }.contains(name)) {
      return text;
    }
    return null;
  }
}
