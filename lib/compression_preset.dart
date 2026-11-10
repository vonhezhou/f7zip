class CompressionPreset {
  const CompressionPreset({
    required this.name,
    this.format = 'zip',
    this.level = 5,
    this.volumeSize = 0,
    this.encryption = 'AES256',
    this.encryptNames = true,
  });

  factory CompressionPreset.fromJson(Map<dynamic, dynamic> json) {
    const formats = {
      'zip',
      '7z',
      'tar',
      'tar.gz',
      'tar.bz2',
      'tar.xz',
      'gz',
      'xz',
      'bz2',
    };
    const levels = {0, 1, 5, 7, 9};
    final rawName = json['name'];
    final name = rawName is String ? rawName.trim() : '';
    final format = formats.contains(json['format'])
        ? json['format'] as String
        : 'zip';
    final rawLevel = json['level'];
    final rawVolume = json['volumeSize'];
    final volume =
        rawVolume is int &&
            rawVolume >= 0 &&
            rawVolume <= 2097151 * 1048576 &&
            rawVolume % 1048576 == 0
        ? rawVolume
        : 0;
    return CompressionPreset(
      name: name.length <= 40 ? name : name.substring(0, 40),
      format: format,
      level: rawLevel is int && levels.contains(rawLevel) ? rawLevel : 5,
      volumeSize: const {'zip', '7z'}.contains(format) ? volume : 0,
      encryption: json['encryption'] == 'ZipCrypto' ? 'ZipCrypto' : 'AES256',
      encryptNames: json['encryptNames'] is bool
          ? json['encryptNames'] as bool
          : true,
    );
  }

  final String name;
  final String format;
  final int level;
  final int volumeSize;
  final String encryption;
  final bool encryptNames;

  Map<String, dynamic> toJson() => {
    'name': name,
    'format': format,
    'level': level,
    'volumeSize': volumeSize,
    'encryption': encryption,
    'encryptNames': encryptNames,
  };
}
