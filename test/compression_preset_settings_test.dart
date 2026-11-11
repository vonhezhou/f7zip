import 'package:f7zip/app_settings.dart';
import 'package:f7zip/app_theme.dart';
import 'package:f7zip/compression_preset.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  const original = AppSettings(
    smartExtraction: true,
    colorTheme: AppColorTheme.green,
    compressionPresets: [CompressionPreset(name: '已有')],
    defaultCompressionPreset: '已有',
  );

  testWidgets('设置内新建预设、校验重名、编辑完整参数并跟随默认名称保存', (tester) async {
    _setSize(tester);
    Map<dynamic, dynamic> persisted = original.toJson();
    var saves = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'saveSettings') {
        saves++;
        persisted = Map.from(call.arguments as Map);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await _mount(tester, () => AppSettings.fromJson(persisted));
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('newCompressionPreset')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compressionPassword')), findsNothing);
    await tester.tap(find.text('保存预设'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 1–40 个字符的名称'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('presetName')), '已有');
    await tester.tap(find.text('保存预设'));
    await tester.pumpAndSettle();
    expect(find.textContaining('预设名称已存在'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('presetName')), '备份');
    await _choose(tester, const ValueKey('compressionFormat'), '7z · 压缩率优先');
    await _choose(tester, const ValueKey('compressionLevel:7z'), '极限');
    await _choose(tester, const ValueKey('volumeSize'), '自定义');
    await tester.enterText(find.byKey(const ValueKey('customVolumeSize')), '3');
    await tester.ensureVisible(find.text('同时加密文件名'));
    await tester.tap(find.text('同时加密文件名'));
    await tester.ensureVisible(find.text('高级压缩参数'));
    await tester.tap(find.text('高级压缩参数'));
    await tester.pumpAndSettle();
    await _choose(tester, const ValueKey('compressionDictionary:0'), '1 MiB');
    await _choose(tester, const ValueKey('compressionSolid:-1'), '16 MiB');
    await _choose(tester, const ValueKey('compressionThreads:0'), '2');
    await tester.tap(find.text('保存预设'));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(find.byKey(const ValueKey('settingsPreset:备份')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('defaultPreset:备份')));
    await tester.tap(find.byKey(const ValueKey('defaultPreset:备份')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editPreset:备份')));
    await tester.pumpAndSettle();
    expect(find.text('7z · 压缩率优先'), findsOneWidget);
    expect(find.text('极限'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('customVolumeSize')))
          .controller!
          .text,
      '3',
    );
    await tester.enterText(find.byKey(const ValueKey('presetName')), '共享备份');
    await tester.tap(find.text('保存预设'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('defaultCompressionPreset')),
          )
          .initialValue,
      '共享备份',
    );
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    final restored = AppSettings.fromJson(persisted);
    expect(restored.defaultCompressionPreset, '共享备份');
    final preset = restored.compressionPresets.last;
    expect(preset.name, '共享备份');
    expect(preset.format, '7z');
    expect(preset.level, 9);
    expect(preset.volumeSize, 3 * 1048576);
    expect(preset.encryptNames, isFalse);
    expect(preset.parameters.toJson(), {
      'method': 'auto',
      'dictionaryMiB': 1,
      'threads': 2,
      'solidMiB': 16,
    });
    expect(restored.smartExtraction, isTrue);
    expect(restored.colorTheme, AppColorTheme.green);
    expect(saves, 1);
    await _open(tester);
    expect(find.byKey(const ValueKey('settingsPreset:共享备份')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预设不依赖输入文件，取消放弃修改，删除默认预设失败后可以重试保存', (tester) async {
    _setSize(tester);
    Map<dynamic, dynamic> persisted = original.toJson();
    var reject = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'saveSettings') {
        if (reject) throw PlatformException(code: 'write', message: '写入失败');
        persisted = Map.from(call.arguments as Map);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await _mount(tester, () => AppSettings.fromJson(persisted));
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('newCompressionPreset')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('presetName')), '单文件');
    await _choose(tester, const ValueKey('compressionFormat'), 'GZIP · 单文件');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存预设'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('保存预设'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(persisted, original.toJson());
    await _open(tester);
    expect(find.byKey(const ValueKey('settingsPreset:单文件')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('editPreset:已有')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('presetName')), '改名');
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settingsPreset:已有')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('deletePreset:已有')));
    await tester.pumpAndSettle();
    expect(find.text('暂无压缩预设'), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('defaultCompressionPreset')),
          )
          .initialValue,
      '',
    );
    reject = true;
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('写入失败'), findsOneWidget);
    expect(persisted, original.toJson());
    reject = false;
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(persisted['compressionPresets'], isEmpty);
    expect(persisted['defaultCompressionPreset'], '');
    expect(persisted['smartExtraction'], isTrue);
    expect(tester.takeException(), isNull);
  });
}

void _setSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(860, 580);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _mount(
  WidgetTester tester,
  AppSettings Function() settings,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<AppSettings>(
              context: context,
              builder: (_) => SettingsDialog(initial: settings()),
            ),
            child: const Text('打开设置'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('压缩'));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, Key key, String label) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label).last);
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}
