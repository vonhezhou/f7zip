import 'dart:io';

import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');

  testWidgets('保存分卷预设与默认值，重启后 Finder 配置压缩复用实际参数', (tester) async {
    _setSize(tester);
    final root = Directory.systemTemp.createTempSync('f7zip-presets-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(p.join(root.path, 'payload.txt'))
      ..writeAsStringSync('payload');
    final archive = p.join(root.path, 'created.7z');
    Map<dynamic, dynamic> persisted = {};
    var finderRequest = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadSettings') return persisted;
      if (call.method == 'saveSettings') {
        persisted = Map<dynamic, dynamic>.from(call.arguments as Map);
      }
      if (call.method == 'chooseInputs') return [source.path];
      if (call.method == 'saveArchive') {
        expect((call.arguments as String).endsWith('.7z'), isTrue);
        return archive;
      }
      if (call.method == 'takeFinderRequests' && finderRequest) {
        finderRequest = false;
        return [
          {
            'action': 'compress',
            'paths': [source.path],
          },
        ];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建压缩包').last);
    await tester.pumpAndSettle();
    await _choose(
      tester,
      find.byKey(const ValueKey('compressionFormat')),
      '7z · 压缩率优先',
    );
    await _choose(tester, find.byType(DropdownButtonFormField<int>), '极限');
    await _choose(tester, find.byKey(const ValueKey('volumeSize')), '自定义');
    await tester.enterText(find.byKey(const ValueKey('customVolumeSize')), '3');
    await tester.enterText(
      find.byKey(const ValueKey('compressionPassword')),
      'per-task-secret',
    );
    await tester.tap(find.text('同时加密文件名'));
    await tester.tap(find.byTooltip('保存压缩预设'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('presetName')), '共享分卷');
    await tester.tap(find.byKey(const ValueKey('presetDefault')));
    await tester.tap(find.widgetWithText(FilledButton, '保存预设'));
    await tester.pumpAndSettle();
    expect(persisted['defaultCompressionPreset'], '共享分卷');
    final preset = (persisted['compressionPresets'] as List).single as Map;
    expect(preset['format'], '7z');
    expect(preset['level'], 9);
    expect(preset['volumeSize'], 3 * 1048576);
    expect(preset['encryptNames'], isFalse);
    expect(preset.containsKey('password'), isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    finderRequest = true;
    await tester.pumpWidget(const F7ZipApp());
    await _until(
      tester,
      () =>
          find.byKey(const ValueKey('compressionPreset')).evaluate().isNotEmpty,
    );
    expect(find.text('共享分卷 · 默认'), findsOneWidget);
    expect(find.text('7z · 压缩率优先'), findsOneWidget);
    expect(find.text('极限'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('customVolumeSize')))
          .controller!
          .text,
      '3',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('compressionPassword')))
          .controller!
          .text,
      '',
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, '同时加密文件名'),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.text('选择保存位置'));
    await _until(tester, () => find.text('只读浏览').evaluate().isNotEmpty);
    expect(File('$archive.001').existsSync(), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('切换预设刷新格式、等级和加密控件，流格式遵守输入限制', (tester) async {
    _setSize(tester);
    final root = Directory.systemTemp.createTempSync('f7zip-presets-switch-');
    addTearDown(() => root.deleteSync(recursive: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'chooseInputs') return [root.path];
      if (call.method == 'loadSettings') {
        return {
          'compressionPresets': [
            {'name': '打包', 'format': 'tar'},
            {'name': '单文件', 'format': 'gz'},
            {
              'name': '兼容',
              'format': 'zip',
              'level': 1,
              'encryption': 'ZipCrypto',
            },
          ],
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建压缩包').last);
    await tester.pumpAndSettle();
    await _choose(
      tester,
      find.byKey(const ValueKey('compressionPreset')),
      '打包',
    );
    expect(find.text('TAR · 仅打包'), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byType(DropdownButtonFormField<int>),
          )
          .onChanged,
      isNull,
    );
    expect(find.byKey(const ValueKey('compressionPassword')), findsNothing);
    await _choose(
      tester,
      find.byKey(const ValueKey('compressionPreset')),
      '单文件',
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '选择保存位置'))
          .onPressed,
      isNull,
    );
    await _choose(
      tester,
      find.byKey(const ValueKey('compressionPreset')),
      '兼容',
    );
    expect(find.text('ZIP · 兼容性优先'), findsOneWidget);
    expect(find.text('最快'), findsOneWidget);
    expect(find.text('ZipCrypto · 兼容旧解压工具'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '选择保存位置'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('设置选择默认预设，同名更新保留默认选择', (tester) async {
    _setSize(tester);
    final root = Directory.systemTemp.createTempSync('f7zip-presets-default-');
    addTearDown(() => root.deleteSync(recursive: true));
    Map<dynamic, dynamic> persisted = {
      'smartExtraction': true,
      'compressionPresets': [
        {'name': '常用', 'format': '7z', 'level': 9},
      ],
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadSettings') return persisted;
      if (call.method == 'chooseInputs') return [root.path];
      if (call.method == 'saveSettings') {
        persisted = Map<dynamic, dynamic>.from(call.arguments as Map);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('压缩'));
    await tester.pumpAndSettle();
    await _choose(
      tester,
      find.byKey(const ValueKey('defaultCompressionPreset')),
      '常用',
    );
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(persisted['defaultCompressionPreset'], '常用');
    expect(persisted['smartExtraction'], isTrue);
    await tester.tap(find.text('新建压缩包').last);
    await tester.pumpAndSettle();
    expect(find.text('7z · 压缩率优先'), findsOneWidget);
    await _choose(
      tester,
      find.byKey(const ValueKey('compressionFormat')),
      'TAR · 仅打包',
    );
    await tester.tap(find.byTooltip('保存压缩预设'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('presetName')), '常用');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('presetDefault')))
          .value,
      isTrue,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存预设'));
    await tester.pumpAndSettle();
    expect((persisted['compressionPresets'] as List).length, 1);
    expect(
      ((persisted['compressionPresets'] as List).single as Map)['format'],
      'tar',
    );
    expect(persisted['defaultCompressionPreset'], '常用');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('预设保存失败保留原配置，可重试删除默认预设', (tester) async {
    _setSize(tester);
    final root = Directory.systemTemp.createTempSync('f7zip-presets-retry-');
    addTearDown(() => root.deleteSync(recursive: true));
    Map<dynamic, dynamic> persisted = {
      'compressionPresets': [
        {'name': '默认', 'format': 'zip'},
      ],
      'defaultCompressionPreset': '默认',
    };
    var reject = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadSettings') return persisted;
      if (call.method == 'chooseInputs') return [root.path];
      if (call.method == 'saveSettings') {
        if (reject) throw PlatformException(code: 'disk', message: '写入失败');
        persisted = Map<dynamic, dynamic>.from(call.arguments as Map);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建压缩包').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除压缩预设'));
    await tester.pumpAndSettle();
    expect(find.textContaining('预设保存失败'), findsOneWidget);
    expect(find.text('默认 · 默认'), findsOneWidget);
    expect((persisted['compressionPresets'] as List).length, 1);
    reject = false;
    await tester.tap(find.byTooltip('删除压缩预设'));
    await tester.pumpAndSettle();
    expect(persisted['compressionPresets'], isEmpty);
    expect(persisted['defaultCompressionPreset'], '');
    expect(find.text('自定义设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpWidget(const SizedBox());
  });
}

void _setSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1120, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _choose(WidgetTester tester, Finder dropdown, String text) async {
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 150 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(ready(), isTrue);
}
