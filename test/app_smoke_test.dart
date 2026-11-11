import 'dart:io';
import 'dart:ui' as ui;

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:f7zip/archive_tree.dart';
import 'package:f7zip/app_theme.dart';
import 'package:f7zip/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('选中目录匹配子文件，兼容反斜杠路径并排除同名前缀的目录', () {
    ArchiveEntry entry(String path) => ArchiveEntry(
      index: 0,
      path: path,
      size: 0,
      packed: 0,
      directory: false,
      encrypted: false,
      modified: 0,
    );
    expect(
      entry(r'folder\nested\file.txt').isSelectedBy({'folder/nested'}),
      isTrue,
    );
    expect(entry('folder/').isSelectedBy({'folder'}), isTrue);
    expect(entry('./folder/file.txt').normalizedPath, 'folder/file.txt');
    expect(entry('./').normalizedPath, '');
    expect(entry('folder-other/file.txt').isSelectedBy({'folder'}), isFalse);
    expect(entry('folder/file.txt').isSelectedBy({'folder/file.txt'}), isTrue);
    expect(entry('folder/file.txt').isSelectedBy({}), isFalse);
  });

  test('文件树补齐省略的父目录，保留空目录并按目录优先排序', () {
    ArchiveEntry entry(String path, {bool directory = false}) => ArchiveEntry(
      index: 0,
      path: path,
      size: 0,
      packed: 0,
      directory: directory,
      encrypted: false,
      modified: 0,
    );
    final root = buildArchiveTree([
      entry('readme.txt'),
      entry(r'docs\nested\plan.txt'),
      entry('docs/empty/', directory: true),
      entry('docs/', directory: true),
      entry('A.txt'),
    ]);
    expect(root.children.map((node) => node.path), [
      'docs',
      'A.txt',
      'readme.txt',
    ]);
    final docs = root.children.first;
    expect(docs.children.map((node) => node.path), [
      'docs/empty',
      'docs/nested',
    ]);
    expect(docs.children.first.children, isEmpty);
    expect(docs.children.last.children.single.path, 'docs/nested/plan.txt');
  });

  test('Dart isolate 通过实际 FFI 完成加密压缩、浏览和解压', () async {
    final root = Directory.systemTemp.createTempSync('f7zip-dart-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(p.join(root.path, '中文.txt'))
      ..writeAsStringSync('Dart → FFI → 7-Zip');
    final archive = p.join(root.path, 'encrypted.7z');
    final engine = ArchiveEngine();
    await engine.run(
      ArchiveRequest(
        'compress',
        archive,
        inputs: [source.path],
        format: '7z',
        password: 'test-password',
      ),
    );
    await expectLater(
      engine.run(ArchiveRequest('list', archive)),
      throwsA(isA<ArchiveFailure>()),
    );
    final listing = await engine.run(
      ArchiveRequest('list', archive, password: 'test-password'),
    );
    expect((listing['items'] as List).single['path'], '中文.txt');
    final destination = p.join(root.path, 'output');
    await engine.run(
      ArchiveRequest(
        'extract',
        archive,
        destination: destination,
        password: 'test-password',
      ),
    );
    expect(
      File(p.join(destination, '中文.txt')).readAsStringSync(),
      'Dart → FFI → 7-Zip',
    );
    expect(engine.progress(), isNull);
  });

  testWidgets(
    '欢迎页与实际打开压缩包后的文件列表正常显示',
    (tester) async {
      // 使用真实桌面布局，覆盖自绘窗口控件占用的宽度。
      const managerChannel = MethodChannel('window_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        managerChannel,
        (call) async => call.method == 'isFocused',
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          managerChannel,
          null,
        ),
      );
      const windowChannel = MethodChannel('sevenzip/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        (call) async => call.method == 'state'
            ? {'focused': true, 'fullScreen': false}
            : null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          null,
        );
      });
      await tester.runAsync(() async {
        final font = FontLoader('.AppleSystemUIFont');
        for (final path in [
          '/System/Library/Fonts/SFNS.ttf',
          '/System/Library/Fonts/STHeiti Light.ttc',
        ]) {
          final bytes = File(path).readAsBytesSync();
          font.addFont(Future.value(ByteData.sublistView(bytes)));
        }
        await font.load();
        // 测试进程显式注册完整中文回退字体，避免截图出现缺字。
        await (FontLoader('PingFang SC')..addFont(
              Future.value(
                ByteData.sublistView(
                  File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
                      .readAsBytesSync(),
                ),
              ),
            ))
            .load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      tester.view.physicalSize = const Size(1120, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, '欢迎使用.txt'))
        ..writeAsStringSync('F7Zip UI smoke test');
      final archive = p.join(root.path, '示例压缩包.zip');
      final documents = Directory(p.join(root.path, '资料'))..createSync();
      Directory(p.join(documents.path, '项目')).createSync();
      Directory(p.join(documents.path, '空目录')).createSync();
      File(p.join(documents.path, '项目', '计划.txt')).writeAsStringSync('文件树联动验证');
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest(
            'compress',
            archive,
            inputs: [source.path, documents.path],
          ),
        ),
      );
      const channel = MethodChannel('sevenzip/desktop');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'loadSettings') {
              return {'singleClickOpen': false};
            }
            if (call.method == 'openArchive') return [archive];
            if (call.method == 'chooseInputs') return [source.path];
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: key, child: const F7ZipApp()),
      );
      await tester.pumpAndSettle();
      expect(find.text('文件打包，从容有序'), findsOneWidget);
      final controlsX = tester.getCenter(find.byType(WindowControls)).dx;
      expect(
        controlsX,
        windowControlsOnLeft ? lessThan(100) : greaterThan(1000),
      );
      await tester.runAsync(() => _capture(key, '/tmp/f7zip-welcome.png'));
      await tester.runAsync(
        () => _capture(
          key,
          '/tmp/f7zip-${defaultTargetPlatform.name}-welcome.png',
        ),
      );
      tester.view.physicalSize = const Size(860, 580);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () => _capture(key, '/tmp/f7zip-welcome-compact.png'),
      );
      tester.view.physicalSize = const Size(1120, 700);
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开压缩包'));
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.text('欢迎使用.txt').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
      expect(find.text('欢迎使用.txt'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => _capture(key, '/tmp/f7zip-browser.png'));
      await tester.enterText(find.byType(TextField), '不存在的文件');
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配的文件'), findsOneWidget);
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('row:欢迎使用.txt')), findsOneWidget);
      expect(find.byTooltip('清除搜索'), findsNothing);
      tester.view.physicalSize = const Size(860, 580);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () => _capture(key, '/tmp/f7zip-browser-compact.png'),
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => _capture(key, '/tmp/f7zip-browser-dark.png'));
      await tester.runAsync(
        () => _capture(
          key,
          '/tmp/f7zip-${defaultTargetPlatform.name}-browser-dark.png',
        ),
      );
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('保存设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () => _capture(key, '/tmp/f7zip-settings-dark.png'),
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();
      expect(find.text('选择保存位置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () => _capture(key, '/tmp/f7zip-compression-dark.png'),
      );
      await tester.tap(find.text('取消'));
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      tester.view.physicalSize = const Size(1120, 700);
      await tester.pumpAndSettle();
      await tester.tap(find.text('欢迎使用.txt').last);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tree:资料')));
      await tester.pumpAndSettle();
      expect(find.text('示例压缩包.zip / 资料'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('expand:资料/项目')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tree:资料/项目/计划.txt')));
      await tester.pumpAndSettle();
      expect(find.text('示例压缩包.zip / 资料/项目'), findsOneWidget);
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.runAsync(() => _capture(key, '/tmp/f7zip-tree.png'));
      await tester.tap(find.byKey(const ValueKey('tree:资料/空目录')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('row:navigation:.')), findsNothing);
      expect(find.byKey(const ValueKey('row:navigation:..')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('row:navigation:..')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey('row:navigation:..')));
      await tester.pumpAndSettle();
      expect(find.text('示例压缩包.zip / 资料'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('row:navigation:..')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey('row:navigation:..')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('row:navigation:..')), findsNothing);
      expect(find.byKey(const ValueKey('row:欢迎使用.txt')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
  testWidgets('主题设置持久化、原生外观同步和系统切换保留当前文件选择', (tester) async {
    tester.view.physicalSize = const Size(1120, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final root = Directory.systemTemp.createTempSync('f7zip-theme-');
    addTearDown(() => root.deleteSync(recursive: true));
    final folder = Directory(p.join(root.path, 'Documents'))..createSync();
    final files = [
      File(p.join(folder.path, 'Notes.txt'))..writeAsStringSync('notes'),
      File(p.join(folder.path, 'Report.csv'))..writeAsStringSync('a,b'),
    ];
    final archive = p.join(root.path, 'Sample.zip');
    await tester.runAsync(
      () => ArchiveEngine().run(
        ArchiveRequest('compress', archive, inputs: [folder.path]),
      ),
    );
    final calls = <MethodCall>[];
    Map<String, dynamic> persisted = {
      'themeMode': 'dark',
      'colorTheme': 'green',
    };
    const channel = MethodChannel('sevenzip/desktop');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'loadSettings') return persisted;
          if (call.method == 'saveSettings') {
            persisted = Map<String, dynamic>.from(call.arguments as Map);
          }
          if (call.method == 'takeFinderRequests') {
            return [
              {
                'action': 'open',
                'paths': [archive],
              },
            ];
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: const F7ZipApp()));
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byKey(const ValueKey('row:Documents')).evaluate().isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
    Brightness brightness() =>
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness;
    expect(brightness(), Brightness.dark);
    ColorScheme colorScheme() =>
        Theme.of(tester.element(find.byType(Scaffold).first)).colorScheme;
    expect(
      colorScheme(),
      buildAppTheme(
        Brightness.dark,
        colorTheme: AppColorTheme.green,
      ).colorScheme,
    );
    await tester.tap(find.byKey(const ValueKey('row:Documents')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('row:Documents/Notes.txt')),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => _capture(key, '/tmp/f7zip-theme-dark.png'));
    Future<void> chooseTheme(String label, {AppColorTheme? colorTheme}) async {
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('主题'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('themeMode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      if (colorTheme != null) {
        await tester.tap(find.byKey(ValueKey('colorTheme:${colorTheme.name}')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
    }

    await chooseTheme('浅色', colorTheme: AppColorTheme.rose);
    expect(brightness(), Brightness.light);
    expect(persisted['colorTheme'], 'rose');
    expect(
      colorScheme(),
      buildAppTheme(
        Brightness.light,
        colorTheme: AppColorTheme.rose,
      ).colorScheme,
    );
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('colorTheme:blue')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(AlertDialog))).colorScheme,
      buildAppTheme(
        Brightness.light,
        colorTheme: AppColorTheme.blue,
      ).colorScheme,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(persisted['colorTheme'], 'rose');
    expect(
      colorScheme(),
      buildAppTheme(
        Brightness.light,
        colorTheme: AppColorTheme.rose,
      ).colorScheme,
    );
    expect(
      calls
          .lastWhere((call) => call.method == 'saveSettings')
          .arguments['themeMode'],
      'light',
    );
    expect(
      calls.lastWhere((call) => call.method == 'setAppearance').arguments,
      'light',
    );
    await tester.runAsync(() => _capture(key, '/tmp/f7zip-theme-light.png'));
    await chooseTheme('跟随系统');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    tester.view.physicalSize = const Size(860, 580);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.text('Sample.zip / Documents'), findsOneWidget);
    expect(
      calls.lastWhere((call) => call.method == 'setAppearance').arguments,
      'system',
    );
    expect(files.every((file) => file.existsSync()), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const F7ZipApp());
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (colorScheme() ==
              buildAppTheme(
                Brightness.light,
                colorTheme: AppColorTheme.rose,
              ).colorScheme &&
          find.byKey(const ValueKey('row:Documents')).evaluate().isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
    expect(
      colorScheme(),
      buildAppTheme(
        Brightness.light,
        colorTheme: AppColorTheme.rose,
      ).colorScheme,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final removeRoot in [false, true]) {
    testWidgets('Finder 冷启动请求按顺序打开和解压，不丢失排队操作 removeRoot=$removeRoot', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1120, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-finder-');
      addTearDown(() => root.deleteSync(recursive: true));
      final wrapped = Directory(p.join(root.path, 'wrapper'))..createSync();
      File(p.join(wrapped.path, 'service.txt'))
          .writeAsStringSync('Finder request');
      final archive = p.join(root.path, 'queued.zip');
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest('compress', archive, inputs: [wrapped.path]),
        ),
      );
      const channel = MethodChannel('sevenzip/desktop');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'loadSettings') {
              return {'removeRedundantRoot': removeRoot};
            }
            if (call.method == 'takeFinderRequests') {
              return [
                {
                  'action': 'open',
                  'paths': [archive],
                },
                {
                  'action': 'extract',
                  'paths': [archive],
                },
              ];
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(const F7ZipApp());
      final output = File(
        p.joinAll([
          root.path,
          'queued',
          if (!removeRoot) 'wrapper',
          'service.txt',
        ]),
      );
      for (var attempt = 0; attempt < 150; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (output.existsSync() &&
            find.textContaining('解压完成 ·').evaluate().isNotEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(output.readAsStringSync(), 'Finder request');
      expect(find.textContaining('解压完成 ·'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Future<void> _capture(GlobalKey key, String path) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
