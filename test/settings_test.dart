import 'package:f7zip/app_settings.dart';
import 'package:f7zip/app_theme.dart';
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
      colorTheme: AppColorTheme.teal,
      alternateRows: false,
      singleClickOpen: false,
      showDotEntries: false,
      viewer: '/Applications/Viewer.app',
      editor: '/Applications/Editor.app',
    );
    expect(AppSettings.fromJson(settings.toJson()).toJson(), settings.toJson());
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
    await tester.ensureVisible(find.text('单击打开文件和文件夹'));
    await tester.tap(find.text('单击打开文件和文件夹'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('显示返回上一级目录项（..）'));
    await tester.tap(find.text('显示返回上一级目录项（..）'));
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
    expect(saved!.singleClickOpen, isFalse);
    expect(saved!.showDotEntries, isFalse);
    expect(saved!.viewer, '/Applications/Viewer.app');
    expect(
      calls.lastWhere((call) => call.method == 'saveSettings').arguments,
      saved!.toJson(),
    );
    expect(tester.takeException(), isNull);
  });
}
