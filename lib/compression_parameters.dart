/// 创建参数的格式约束，供表单和持久化预设共用。
class CompressionParameters {
  const CompressionParameters({
    this.method = 'auto',
    this.dictionaryMiB = 0,
    this.threads = 0,
    this.solidMiB = -1,
  });

  static const dictionaries = [0, 1, 4, 8, 16, 32, 64, 128, 256];
  static const solidBlocks = [-1, 0, 16, 64, 256, 1024];

  static List<String> methodsFor(String format) => switch (format) {
    'zip' || 'zip-aes256' => [
      'auto',
      'Copy',
      'Deflate',
      'Deflate64',
      'BZip2',
      'LZMA',
      'PPMd',
    ],
    'zipx' || 'zipx-aes256' => ['auto', 'Copy', 'LZMA', 'BZip2', 'PPMd'],
    'sfx' || 'sfx-visible' => ['auto', 'Copy', 'LZMA2', 'LZMA', 'PPMd'],
    '7z' || '7z-visible' => ['auto', 'Copy', 'LZMA2', 'LZMA', 'PPMd', 'BZip2'],
    _ => ['auto'],
  };

  static String defaultMethod(String format) => switch (format) {
    'zipx' || 'zipx-aes256' => 'LZMA',
    'zip' || 'zip-aes256' || 'gz' || 'tar.gz' => 'Deflate',
    'sfx' ||
    'sfx-visible' ||
    '7z' ||
    '7z-visible' ||
    'xz' ||
    'tar.xz' => 'LZMA2',
    'bz2' || 'tar.bz2' => 'BZip2',
    _ => 'Copy',
  };

  final String method;
  final int dictionaryMiB;
  final int threads;
  final int solidMiB;

  String effectiveMethod(String format, int level) =>
      level == 0 &&
          const {
            'zip',
            'zip-aes256',
            'zipx',
            'zipx-aes256',
            '7z',
            '7z-visible',
            'sfx',
            'sfx-visible',
          }.contains(format)
      ? 'Copy'
      : method == 'auto'
      ? defaultMethod(format)
      : method;

  bool supportsDictionary(String format, int level) =>
      level != 0 &&
      const {'LZMA', 'LZMA2', 'PPMd'}.contains(effectiveMethod(format, level));

  static bool supportsThreads(String format) =>
      !const {'tar', 'gz', 'tar.gz', 'wim'}.contains(format);

  bool supportsSolid(String format, int level) =>
      const {'7z', '7z-visible', 'sfx', 'sfx-visible'}.contains(format) &&
      effectiveMethod(format, level) != 'Copy';

  CompressionParameters forFormat(String format, int level) {
    final selected = CompressionParameters(
      method: level != 0 && methodsFor(format).contains(method)
          ? method
          : 'auto',
    );
    return CompressionParameters(
      method: selected.method,
      dictionaryMiB:
          selected.supportsDictionary(format, level) &&
              dictionaries.contains(dictionaryMiB)
          ? dictionaryMiB
          : 0,
      threads: supportsThreads(format) && threads >= 0 && threads <= 64
          ? threads
          : 0,
      solidMiB:
          selected.supportsSolid(format, level) &&
              solidBlocks.contains(solidMiB)
          ? solidMiB
          : -1,
    );
  }

  factory CompressionParameters.fromJson(dynamic value) {
    if (value is! Map) return const CompressionParameters();
    return CompressionParameters(
      method: value['method'] is String ? value['method'] as String : 'auto',
      dictionaryMiB: value['dictionaryMiB'] is int
          ? value['dictionaryMiB'] as int
          : 0,
      threads: value['threads'] is int ? value['threads'] as int : 0,
      solidMiB: value['solidMiB'] is int ? value['solidMiB'] as int : -1,
    );
  }

  Map<String, dynamic> toJson() => {
    'method': method,
    'dictionaryMiB': dictionaryMiB,
    'threads': threads,
    'solidMiB': solidMiB,
  };
}
