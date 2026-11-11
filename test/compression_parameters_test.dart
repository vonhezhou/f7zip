import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/compression_parameters.dart';
import 'package:f7zip/compression_preset.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('ZIPX 默认 LZMA 并保留有效预设，WIM 归一化为存储且清除高级参数', () {
    final zipx = CompressionPreset.fromJson({
      'name': 'ZIPX',
      'format': 'zipx',
      'volumeSize': 1048576,
      'parameters': {'dictionaryMiB': 1, 'threads': 2},
    });
    expect(zipx.format, 'zipx');
    expect(zipx.volumeSize, 1048576);
    expect(zipx.parameters.effectiveMethod('zipx', zipx.level), 'LZMA');
    expect(zipx.parameters.dictionaryMiB, 1);
    expect(zipx.parameters.effectiveMethod('zipx', 0), 'Copy');
    final wim = CompressionPreset.fromJson({
      'name': 'WIM',
      'format': 'wim',
      'level': 9,
      'volumeSize': 1048576,
      'parameters': {
        'method': 'LZMA',
        'dictionaryMiB': 64,
        'threads': 4,
        'solidMiB': 16,
      },
    });
    expect(wim.format, 'wim');
    expect(wim.level, 0);
    expect(wim.volumeSize, 0);
    expect(wim.parameters.toJson(), const CompressionParameters().toJson());
  });
  test('高级参数兼容旧预设，清除损坏和不兼容组合，密码重试保留参数', () {
    expect(
      CompressionPreset.fromJson({'name': '旧'}).parameters.toJson(),
      const CompressionParameters().toJson(),
    );
    const parameters = CompressionParameters(
      method: 'LZMA2',
      dictionaryMiB: 1,
      threads: 2,
      solidMiB: 16,
    );
    final preset = CompressionPreset.fromJson(
      const CompressionPreset(
        name: '高级',
        format: '7z',
        parameters: parameters,
      ).toJson(),
    );
    expect(preset.parameters.toJson(), parameters.toJson());
    expect(
      ArchiveRequest(
        'compress',
        '/output',
        parameters: parameters,
      ).withPassword('retry').parameters.toJson(),
      parameters.toJson(),
    );
    expect(
      parameters.forFormat('tar', 5).toJson(),
      const CompressionParameters().toJson(),
    );
    expect(
      parameters.forFormat('zip', 5).toJson(),
      const CompressionParameters(threads: 2).toJson(),
    );
    expect(
      parameters.forFormat('7z', 0).toJson(),
      const CompressionParameters(threads: 2).toJson(),
    );
    final broken = CompressionPreset.fromJson({
      'name': '损坏',
      'format': '7z',
      'parameters': {
        'method': 'invalid',
        'dictionaryMiB': 3,
        'threads': 65,
        'solidMiB': -3,
      },
    });
    expect(broken.parameters.toJson(), const CompressionParameters().toJson());
    expect(
      CompressionParameters.fromJson({'dictionaryMiB': '256'}).dictionaryMiB,
      0,
    );
  });

  testWidgets('高级表单选择算法、字典、固实块与线程，保存预设并实际创建', (tester) async {
    tester.view.physicalSize = const Size(1120, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-advanced-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(p.join(root.path, 'source.txt'))
      ..writeAsStringSync('advanced UI payload\n' * 100000);
    final archive = p.join(root.path, 'output.7z');
    Map<dynamic, dynamic> persisted = {};
    const channel = MethodChannel('sevenzip/desktop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'chooseInputs') return [source.path];
      if (call.method == 'saveArchive') return archive;
      if (call.method == 'saveSettings') persisted = call.arguments as Map;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建压缩包').last);
    await tester.pumpAndSettle();
    await _choose(tester, const ValueKey('compressionFormat'), '7z · 压缩率优先');
    await tester.ensureVisible(find.text('高级压缩参数'));
    await tester.tap(find.text('高级压缩参数'));
    await tester.pumpAndSettle();
    await _choose(tester, const ValueKey('compressionMethod:auto'), 'LZMA2');
    await _choose(tester, const ValueKey('compressionDictionary:0'), '1 MiB');
    await _choose(tester, const ValueKey('compressionSolid:-1'), '16 MiB');
    await _choose(tester, const ValueKey('compressionThreads:0'), '2');
    expect(find.textContaining('76 MiB 内存'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('保存压缩预设'));
    await tester.tap(find.byTooltip('保存压缩预设'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('presetName')), '高级');
    await tester.tap(find.widgetWithText(FilledButton, '保存预设'));
    await tester.pumpAndSettle();
    final preset = (persisted['compressionPresets'] as List).single as Map;
    expect(preset['parameters'], {
      'method': 'LZMA2',
      'dictionaryMiB': 1,
      'threads': 2,
      'solidMiB': 16,
    });
    await tester.tap(find.text('选择保存位置'));
    for (var i = 0; i < 150; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.text('source.txt').evaluate().isNotEmpty &&
          File(archive).existsSync()) {
        break;
      }
    }
    await tester.pumpAndSettle();
    expect(File(archive).existsSync(), isTrue);
    final listed = await tester.runAsync(
      () => ArchiveEngine().run(ArchiveRequest('list', archive)),
    );
    final item = (listed!['items'] as List).firstWhere(
      (item) => item['path'] == 'source.txt',
    ) as Map;
    expect(item['method'], contains('LZMA2:20'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _choose(WidgetTester tester, Key key, String text) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}
