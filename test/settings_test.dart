import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:f7zip/app_settings.dart';
import 'package:f7zip/app_theme.dart';
import 'package:f7zip/main.dart';
import 'package:f7zip/filename_encoding.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sevenzip/desktop');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('旧配置使用默认值，保存和重新加载保留浏览与程序设置', () {
    final defaults = AppSettings.fromJson({});
    expect(defaults.singleClickOpen, isTrue);
    expect(defaults.autoUnpackTar, isTrue);
    expect(defaults.removeRedundantRoot, isFalse);
    expect(defaults.filenameEncoding, FilenameEncoding.autoDetect);
    expect(
      AppSettings.fromJson({'filenameEncoding': 'gbk'}).filenameEncoding,
      FilenameEncoding.gbk,
    );
    expect(
      AppSettings.fromJson({'filenameEncoding': 'invalid'}).filenameEncoding,
      FilenameEncoding.autoDetect,
    );
    expect(defaults.themeMode, ThemeMode.system);
    expect(defaults.colorTheme, AppColorTheme.purple);
    expect(
      AppSettings.fromJson({'colorTheme': 'invalid'}).colorTheme,
      AppColorTheme.purple,
    );
    expect(
      AppSettings.fromJson({'themeMode': 'invalid'}).themeMode,
      ThemeMode.system,
    );
    final settings = const AppSettings(
      themeMode: ThemeMode.dark,
      filenameEncoding: FilenameEncoding.shiftJis,
      colorTheme: AppColorTheme.teal,
      alternateRows: false,
      singleClickOpen: false,
      showDotEntries: false,
      removeRedundantRoot: true,
      autoUnpackTar: false,
      viewer: '/Applications/Viewer.app',
      editor: '/Applications/Editor.app',
    );
    expect(AppSettings.fromJson(settings.toJson()).toJson(), settings.toJson());
    expect(settings.withCompressionPresets([], '').autoUnpackTar, isFalse);
  });

  test('自定义主题文件往返、设置恢复与压缩预设更新保留主题', () {
    const theme = CustomColorTheme(name: '自定义蓝', seedColor: Color(0xFF123456));
    expect(
      CustomColorTheme.importJson(theme.exportJson()).toJson(),
      theme.toJson(),
    );
    const settings = AppSettings(
      customThemes: [theme],
      selectedCustomTheme: '自定义蓝',
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.toJson(), settings.toJson());
    expect(
      restored.withCompressionPresets([], '').customTheme!.toJson(),
      theme.toJson(),
    );
    for (final brightness in Brightness.values) {
      expect(
        buildAppTheme(
          brightness,
          customTheme: restored.customTheme,
        ).colorScheme,
        ColorScheme.fromSeed(
          seedColor: theme.seedColor,
          brightness: brightness,
        ),
      );
    }
    final damaged = AppSettings.fromJson({
      'customThemes': [
        null,
        {'name': '坏颜色', 'seedColor': '#123'},
        theme.toJson(),
        theme.toJson(),
      ],
      'selectedCustomTheme': '不存在',
    });
    expect(damaged.customThemes.length, 1);
    expect(damaged.customTheme, isNull);
    expect(AppSettings.fromJson({}).customThemes, isEmpty);
  });

  test('主题文件拒绝损坏格式、未知版本、无效名称和颜色', () {
    for (final source in [
      'bad json',
      '[]',
      '{}',
      jsonEncode({'format': 'f7zip-theme', 'version': 2}),
      for (final theme in [
        null,
        {'name': '', 'seedColor': '#123456'},
        {'name': 'a' * 81, 'seedColor': '#123456'},
        {'name': '颜色', 'seedColor': '#GGGGGG'},
        {'name': '颜色', 'seedColor': '#80123456'},
        {'name': 123, 'seedColor': '#123456'},
      ])
        jsonEncode({'format': 'f7zip-theme', 'version': 1, 'theme': theme}),
    ]) {
      expect(() => CustomColorTheme.importJson(source), throwsFormatException);
    }
  });

  testWidgets('自定义主题编辑与删除可预览，取消放弃，保存后重启恢复全局配色', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<dynamic, dynamic> persisted = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'loadSettings') return persisted;
          if (call.method == 'saveSettings') {
            persisted = Map.from(call.arguments as Map);
          }
          return null;
        });
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await _revealSetting(tester, '自定义主题…');
    await tester.tap(find.text('自定义主题…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存主题'));
    await tester.pumpAndSettle();
    expect(find.text('请输入主题名称'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('customThemeName')), '夜空');
    await tester.enterText(
      find.byKey(const ValueKey('customThemeColor')),
      '#123456',
    );
    await tester.tap(find.text('保存主题'));
    await tester.pumpAndSettle();
    final expected = buildAppTheme(
      Brightness.light,
      customTheme: const CustomColorTheme(
        name: '夜空',
        seedColor: Color(0xFF123456),
      ),
    ).colorScheme;
    expect(
      Theme.of(tester.element(find.byType(AlertDialog))).colorScheme,
      expected,
    );
    expect(persisted, isEmpty);
    await tester.ensureVisible(find.text('编辑主题'));
    await tester.tap(find.text('编辑主题'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('customThemeName')),
      '夜空蓝',
    );
    await tester.tap(find.text('保存主题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(persisted['selectedCustomTheme'], '夜空蓝');
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme,
      expected,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme,
      expected,
    );
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await _revealSetting(tester, '删除主题');
    await tester.tap(find.text('删除主题'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('customTheme:夜空蓝')), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(persisted['selectedCustomTheme'], '夜空蓝');
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme,
      expected,
    );
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await _revealSetting(tester, '删除主题');
    await tester.tap(find.text('删除主题'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(persisted['customThemes'], isEmpty);
    expect(persisted['selectedCustomTheme'], '');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('原生调色盘实时更新浅深预览，取消恢复原色，确认保存选色', (tester) async {
    const picker = MethodChannel('sevenzip/themeColor');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    Completer<int?>? pending;
    messenger.setMockMethodCallHandler(picker, (call) async {
      expect(call.method, 'chooseColor');
      expect(call.arguments, 0xFF6750A4);
      pending = Completer<int?>();
      return pending!.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(picker, null));
    await tester.pumpWidget(
      const MaterialApp(home: SettingsDialog(initial: AppSettings())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义主题…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('customThemeName')),
      '调色盘主题',
    );
    String hex() => tester
        .widget<TextFormField>(find.byKey(const ValueKey('customThemeColor')))
        .controller!
        .text;
    await tester.tap(find.byKey(const ValueKey('themeColorPicker')));
    await tester.pumpAndSettle();
    const codec = StandardMethodCodec();
    final message = Completer<void>();
    unawaited(
      messenger.handlePlatformMessage(
        'sevenzip/themeColor',
        codec.encodeMethodCall(const MethodCall('colorChanged', 0xFF123456)),
        (_) => message.complete(),
      ),
    );
    await message.future;
    await tester.pumpAndSettle();
    expect(hex(), '#123456');
    for (final brightness in Brightness.values) {
      final preview = find.byKey(ValueKey('themePreview:${brightness.name}'));
      expect(
        Theme.of(tester.element(preview)).colorScheme,
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF123456),
          brightness: brightness,
        ),
      );
    }
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存主题'))
          .onPressed,
      isNull,
    );
    pending!.complete(null);
    await tester.pumpAndSettle();
    expect(hex(), '#6750A4');
    await tester.tap(find.byKey(const ValueKey('themeColorPicker')));
    await tester.pumpAndSettle();
    pending!.complete(0xFF112233);
    await tester.pumpAndSettle();
    expect(hex(), '#112233');
    await tester.tap(find.text('保存主题'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('customTheme:调色盘主题')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主题导入导出真实文件、同名保留、错误和取消保护设置', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-themes-');
    addTearDown(() => root.deleteSync(recursive: true));
    final input = File('${root.path}/input.json');
    final output = File('${root.path}/output.json');
    const theme = CustomColorTheme(name: '导入蓝', seedColor: Color(0xFF112233));
    input.writeAsStringSync(theme.exportJson());
    Map<dynamic, dynamic>? persisted;
    var cancel = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'importTheme') return cancel ? null : input.path;
          if (call.method == 'exportTheme') return output.path;
          if (call.method == 'saveSettings') {
            persisted = Map.from(call.arguments as Map);
          }
          return null;
        });
    await tester.pumpWidget(
      const MaterialApp(home: SettingsDialog(initial: AppSettings())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题'));
    await tester.pumpAndSettle();
    Future<void> transfer(String label) async {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
      // 文件 I/O 在真实事件循环执行，并等待界面退出忙碌状态。
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (tester
                .widget<FilledButton>(find.widgetWithText(FilledButton, '保存设置'))
                .onPressed !=
            null) {
          break;
        }
      }
      await tester.pumpAndSettle();
    }

    await transfer('导入主题…');
    expect(find.byKey(const ValueKey('customTheme:导入蓝')), findsOneWidget);
    await transfer('导入主题…');
    expect(find.byKey(const ValueKey('customTheme:导入蓝 (2)')), findsOneWidget);
    await transfer('导出当前主题…');
    final exported = CustomColorTheme.importJson(output.readAsStringSync());
    expect(exported.name, '导入蓝 (2)');
    expect(exported.seedColor, theme.seedColor);
    input.writeAsStringSync('{}');
    await transfer('导入主题…');
    expect(find.textContaining('导入失败'), findsOneWidget);
    input.writeAsStringSync('a' * 65537);
    await transfer('导入主题…');
    expect(find.textContaining('主题文件超过 64 KiB'), findsOneWidget);
    cancel = true;
    await transfer('导入主题…');
    expect(find.textContaining('导入失败'), findsNothing);
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect((persisted!['customThemes'] as List).length, 2);
    expect(persisted!['selectedCustomTheme'], '导入蓝 (2)');
    expect(tester.takeException(), isNull);
  });

  test('所有颜色主题在浅深色下使用完整的 Material 3 语义色', () {
    for (final colorTheme in AppColorTheme.values) {
      for (final brightness in Brightness.values) {
        final theme = buildAppTheme(brightness, colorTheme: colorTheme);
        final scheme = ColorScheme.fromSeed(
          seedColor: colorTheme.seedColor,
          brightness: brightness,
        );
        expect(theme.colorScheme, scheme);
        final colors = AppColors(scheme);
        expect(colors.canvas, scheme.surface);
        expect(colors.sidebar, scheme.surfaceContainerLow);
        expect(colors.selection, scheme.secondaryContainer);
        expect(colors.onSelection, scheme.onSecondaryContainer);
        expect(colors.tint, scheme.primaryContainer);
        expect(colors.onTint, scheme.onPrimaryContainer);
      }
    }
  });

  testWidgets('设置保存通过持久化接口，程序选择和文件关联需要显式点击', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'fileAssociations') {
            return [
              {
                'extension': 'zip',
                'application': 'Archive Utility',
                'ours': false,
                'canRestore': false,
              },
            ];
          }
          if (call.method == 'chooseApplication') {
            return '/Applications/Viewer.app';
          }
          if (call.method == 'setFileAssociation') {
            return [
              {
                'extension': 'zip',
                'application': 'F7Zip',
                'ours': true,
                'canRestore': true,
              },
            ];
          }
          return null;
        });
    AppSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showDialog<AppSettings>(
                  context: context,
                  builder: (_) => const SettingsDialog(initial: AppSettings()),
                );
              },
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解压'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filenameEncoding')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日文 Shift-JIS').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('colorTheme:green')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(AlertDialog))).colorScheme,
      buildAppTheme(
        Brightness.light,
        colorTheme: AppColorTheme.green,
      ).colorScheme,
    );
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme,
      buildAppTheme(Brightness.light).colorScheme,
    );
    await tester.tap(find.text('常规'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('单击打开文件和文件夹'),
      100,
      scrollable: find.descendant(
        of: find
            .descendant(
              of: find.byType(SettingsDialog),
              matching: find.byType(ListView),
            )
            .first,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('单击打开文件和文件夹'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('显示返回上一级目录项（..）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示返回上一级目录项（..）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解压'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('解压时删除冗余的根目录'),
      100,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('settingsExtraction')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('解压时删除冗余的根目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件关联'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'setFileAssociation'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('associate:zip')));
    await tester.pumpAndSettle();
    expect(
      calls.firstWhere((call) => call.method == 'setFileAssociation').arguments,
      {'extension': 'zip', 'restore': false},
    );
    expect(find.text('已关联'), findsOneWidget);
    await tester.tap(find.text('外部程序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择…').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(saved!.colorTheme, AppColorTheme.green);
    expect(saved!.filenameEncoding, FilenameEncoding.shiftJis);
    expect(saved!.singleClickOpen, isFalse);
    expect(saved!.showDotEntries, isFalse);
    expect(saved!.removeRedundantRoot, isTrue);
    expect(saved!.viewer, '/Applications/Viewer.app');
    expect(
      calls.lastWhere((call) => call.method == 'saveSettings').arguments,
      saved!.toJson(),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _revealSetting(WidgetTester tester, String label) async {
  await tester.tap(find.text('主题'));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text(label),
    100,
    scrollable: find.descendant(
      of: find
          .descendant(
            of: find.byType(SettingsDialog),
            matching: find.byType(ListView),
          )
          .first,
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
}
