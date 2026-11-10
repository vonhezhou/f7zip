import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('单击查看、点目录导航、勾选与外部编辑保存自动回写完整流程', (tester) async {
    await tester.runAsync(() async {
      final font = FontLoader('.AppleSystemUIFont');
      for (final path in [
        '/System/Library/Fonts/SFNS.ttf',
        '/System/Library/Fonts/STHeiti Light.ttc',
      ]) {
        font.addFont(
          Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
        );
      }
      await font.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(1120, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-interaction-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(p.join(root.path, 'readme.txt'))
      ..writeAsStringSync('before');
    final folder = Directory(p.join(root.path, '目录'))..createSync();
    File(p.join(folder.path, '子项.txt')).writeAsStringSync('child');
    final archive = p.join(root.path, 'interaction.zip');
    final engine = ArchiveEngine();
    await tester.runAsync(
      () => engine.run(
        ArchiveRequest('compress', archive, inputs: [source.path, folder.path]),
      ),
    );
    final calls = <MethodCall>[];
    final launches = <Map<String, dynamic>>[];
    const channel = MethodChannel('sevenzip/desktop');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'loadSettings':
              return {
                'singleClickOpen': true,
                'viewer': '/Applications/Viewer.app',
                'editor': '/Applications/Editor.app',
              };
            case 'workspaceDirectory':
              return p.join(root.path, 'sessions');
            case 'takeFinderRequests':
              return [
                {
                  'action': 'open',
                  'paths': [archive],
                },
              ];
            case 'launchFile':
              launches.add(Map<String, dynamic>.from(call.arguments as Map));
              return null;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    addTearDown(() {
      for (final launch in launches) {
        final directory = Directory(
          p.dirname(p.dirname(launch['path'] as String)),
        );
        if (p.basename(directory.path).startsWith('f7zip-view-') &&
            directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      }
    });
    await tester.pumpWidget(const F7ZipApp());
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('row:readme.txt')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const ValueKey('row:navigation:..')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('row:readme.txt')));
    await _pumpUntil(tester, () => launches.length == 1);
    expect(launches.single['application'], '/Applications/Viewer.app');
    expect(
      File(launches.single['path'] as String).readAsStringSync(),
      'before',
    );
    await tester.tap(find.byKey(const ValueKey('row:目录')));
    await tester.pumpAndSettle();
    expect(find.text('interaction.zip / 目录'), findsOneWidget);
    expect(find.byKey(const ValueKey('row:navigation:.')), findsNothing);
    expect(find.byKey(const ValueKey('row:navigation:..')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('row:navigation:..')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('row:readme.txt')), findsOneWidget);
    expect(find.byKey(const ValueKey('row:navigation:.')), findsNothing);
    expect(find.byKey(const ValueKey('row:navigation:..')), findsNothing);
    expect(calls.where((call) => call.method == 'reveal'), isEmpty);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('row:readme.txt')),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await _pumpUntil(tester, () => launches.length == 2);
    expect(launches.last['application'], '/Applications/Editor.app');
    final working = File(launches.last['path'] as String);
    await tester.runAsync(
      () => working.writeAsString('after saving in editor', flush: true),
    );
    await _pumpUntil(
      tester,
      () =>
          find.textContaining('已自动更新压缩包').evaluate().isNotEmpty &&
          find.textContaining('保存后自动更新压缩包').evaluate().isNotEmpty,
    );
    final output = p.join(root.path, 'verified');
    await tester.runAsync(
      () => engine.run(ArchiveRequest('extract', archive, destination: output)),
    );
    expect(
      File(p.join(output, 'readme.txt')).readAsStringSync(),
      'after saving in editor',
    );
    expect(File(p.join(output, '目录/子项.txt')).readAsStringSync(), 'child');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    if (ready()) return;
  }
  fail('异步文件交互未完成');
}
