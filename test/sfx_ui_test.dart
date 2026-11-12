import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/compression_parameters.dart';
import 'package:f7zip/compression_preset.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

void main() {
  test('SFX 预设保留模块支持参数并清除分卷和不支持算法', () {
    final preset = CompressionPreset.fromJson({
      'name': 'SFX',
      'format': 'sfx',
      'volumeSize': 1048576,
      'parameters': {
        'method': 'BZip2',
        'dictionaryMiB': 1,
        'threads': 2,
        'solidMiB': 16,
      },
    });
    expect(preset.format, 'sfx');
    expect(preset.volumeSize, 0);
    expect(preset.parameters.method, 'auto');
    expect(preset.parameters.effectiveMethod('sfx', 5), 'LZMA2');
    expect(preset.parameters.dictionaryMiB, 1);
    expect(preset.parameters.solidMiB, 16);
    expect(CompressionParameters.methodsFor('sfx'), isNot(contains('BZip2')));
    expect(
      CompressionPreset.fromJson(preset.toJson()).toJson(),
      preset.toJson(),
    );
  });
  for (final scenario in ['create', 'encrypted', 'retry']) {
    testWidgets('普通 Windows SFX 创建并以归档方式打开 $scenario', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1120, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-sfx-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, '资料😀.txt'))
        ..writeAsStringSync('SFX through UI');
      final archive = File(p.join(root.path, 'created.exe'));
      if (scenario == 'retry') archive.writeAsStringSync('keep existing');
      const channel = MethodChannel('sevenzip/desktop');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var launches = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'chooseInputs') return [source.path];
        if (call.method == 'saveArchive') return archive.path;
        if (call.method == 'launchFile') launches++;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await tester.pumpAndSettle();
      Future<void> configure() async {
        await tester.tap(find.text('新建压缩包').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('volumeSize')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自定义').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('compressionFormat')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Windows 自解压 EXE · x86').last);
        await tester.tap(find.text('Windows 自解压 EXE · x86').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('volumeSize')), findsNothing);
        expect(find.byKey(const ValueKey('customVolumeSize')), findsNothing);
        expect(find.textContaining('Windows 安全策略'), findsOneWidget);
        if (scenario == 'encrypted') {
          await tester.enterText(
            find.byKey(const ValueKey('compressionPassword')),
            '中文😀 secret',
          );
        }
        await tester.tap(find.text('选择保存位置'));
      }

      await configure();
      if (scenario == 'retry') {
        await _until(tester, () => find.text('知道了').evaluate().isNotEmpty);
        expect(archive.readAsStringSync(), 'keep existing');
        archive.deleteSync();
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        await configure();
      }
      await _until(
        tester,
        () => find.byKey(const ValueKey('row:资料😀.txt')).evaluate().isNotEmpty,
      );
      expect(find.text('只读浏览'), findsOneWidget);
      expect(archive.readAsBytesSync().take(2), [77, 90]);
      expect(launches, 0);
      await tester.runAsync(() async {
        await ArchiveEngine().run(
          ArchiveRequest(
            'test',
            archive.path,
            password: scenario == 'encrypted' ? '中文😀 secret' : '',
          ),
        );
      });
      expect(root.listSync().whereType<Directory>(), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var index = 0; index < 200 && !ready(); index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(ready(), isTrue);
}
