import 'package:f7zip/app_settings.dart';
import 'package:f7zip/app_theme.dart';
import 'package:f7zip/compression_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('预设序列化完整参数，兼容旧配置并保留其他设置', () {
    final original = const AppSettings(
      smartExtraction: true,
      removeRedundantRoot: true,
      colorTheme: AppColorTheme.rose,
      viewer: '/Applications/Viewer.app',
    );
    const preset = CompressionPreset(
      name: '共享',
      format: '7z',
      level: 9,
      volumeSize: 3 * 1048576,
      encryption: 'ZipCrypto',
      encryptNames: false,
    );
    final changed = original.withCompressionPresets([preset], '共享');
    final restored = AppSettings.fromJson(changed.toJson());
    expect(restored.compressionPresets.single.toJson(), preset.toJson());
    expect(restored.defaultCompressionPreset, '共享');
    final before = original.toJson()
      ..remove('compressionPresets')
      ..remove('defaultCompressionPreset');
    final after = restored.toJson()
      ..remove('compressionPresets')
      ..remove('defaultCompressionPreset');
    expect(after, before);
    expect(AppSettings.fromJson({}).compressionPresets, isEmpty);
    expect(AppSettings.fromJson({}).defaultCompressionPreset, '');
  });

  test('损坏参数回退，重复和空名称过滤，失效默认名称清除', () {
    final restored = AppSettings.fromJson({
      'defaultCompressionPreset': 'missing',
      'compressionPresets': [
        null,
        {'name': ''},
        {'name': '共享', 'format': 'invalid', 'level': 123, 'volumeSize': -1},
        {'name': '共享', 'format': '7z'},
        {'name': 'TAR', 'format': 'tar', 'volumeSize': 1048576},
        {'name': 'custom', 'volumeSize': 1048577, 'encryptNames': 'invalid'},
      ],
    });
    expect(restored.defaultCompressionPreset, '');
    expect(restored.compressionPresets.map((preset) => preset.name), [
      '共享',
      'TAR',
      'custom',
    ]);
    expect(restored.compressionPresets.first.format, 'zip');
    expect(restored.compressionPresets.first.level, 5);
    expect(
      CompressionPreset.fromJson({'name': 'number', 'level': 5.0}).level,
      5,
    );
    expect(
      restored.compressionPresets.every((preset) => preset.volumeSize == 0),
      isTrue,
    );
  });

  test('预设持久化只包含压缩参数', () {
    final preset = CompressionPreset.fromJson({
      'name': '临时',
      'password': 'secret',
    });
    expect(
      preset.toJson().keys,
      unorderedEquals([
        'name',
        'format',
        'level',
        'volumeSize',
        'encryption',
        'encryptNames',
      ]),
    );
    expect(preset.toJson().containsValue('secret'), isFalse);
  });
}
