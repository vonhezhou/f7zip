import 'dart:io';

import 'package:f7zip/app_settings.dart';
import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  test('智能解压设置兼容旧数据并序列化', () {
    expect(AppSettings.fromJson({}).smartExtraction, isFalse);
    final settings = AppSettings.fromJson({'smartExtraction': true});
    expect(settings.smartExtraction, isTrue);
    expect(settings.toJson()['smartExtraction'], isTrue);
  });

  for (final shape in [
    'file',
    'folder',
    'multiple',
    'flatFolder',
    'finderTo',
    'finderHere',
  ]) {
    testWidgets('智能解压通过实际 UI 入口处理 $shape', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-smart-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final inputsFolder = Directory(p.join(root.path, 'inputs'))..createSync();
      final first = File(p.join(inputsFolder.path, 'a.txt'))
        ..writeAsStringSync('a');
      final second = File(p.join(inputsFolder.path, 'b.txt'))
        ..writeAsStringSync('b');
      final inputs = switch (shape) {
        'file' => [first.path],
        'folder' || 'flatFolder' => [inputsFolder.path],
        _ => [first.path, second.path],
      };
      final archive = p.join(root.path, 'bundle.zip');
      final output = Directory(p.join(root.path, 'output'))..createSync();
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest('compress', archive, inputs: inputs),
        ),
      );
      final finder = shape.startsWith('finder');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'loadSettings') {
          return {
            'smartExtraction': true,
            'removeRedundantRoot': shape == 'flatFolder',
          };
        }
        if (call.method == 'takeFinderRequests') {
          return [
            {
              'action': finder
                  ? shape == 'finderTo'
                        ? 'extractTo'
                        : 'extractHere'
                  : 'open',
              'paths': [archive],
            },
          ];
        }
        if (call.method == 'chooseFolder') return [output.path];
        if (call.method == 'finderChooseFolder') return output.path;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      if (!finder) {
        await _until(
          tester,
          () => find.textContaining('bundle.zip').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('解压到…'));
      }
      await _until(
        tester,
        () => find.textContaining('解压完成 ·').evaluate().isNotEmpty,
      );
      final expected = switch (shape) {
        'file' => p.join(output.path, 'a.txt'),
        'folder' => p.join(output.path, 'inputs', 'a.txt'),
        'finderHere' => p.join(root.path, 'a.txt'),
        _ => p.join(output.path, 'bundle', 'a.txt'),
      };
      expect(File(expected).readAsStringSync(), 'a');
      if (shape == 'file' || shape == 'folder') {
        expect(Directory(p.join(output.path, 'bundle')).existsSync(), isFalse);
      }
      if (shape == 'finderHere') {
        expect(Directory(p.join(root.path, 'bundle')).existsSync(), isFalse);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('智能解压开关通过设置保存并重启恢复', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map<dynamic, dynamic> persisted = {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadSettings') return persisted;
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
    final toggle = find.byKey(const ValueKey('smartExtraction'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(persisted['smartExtraction'], isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpWidget(const SizedBox());
  });

  for (final enabled in [true, false]) {
    for (final finder in [true, false]) {
      testWidgets('TAR 复合解压实际入口 enabled=$enabled finder=$finder', (
        tester,
      ) async {
        final root = Directory.systemTemp.createTempSync('f7zip-tar-ui-');
        addTearDown(() => root.deleteSync(recursive: true));
        final source = File(p.join(root.path, 'payload.txt'))
          ..writeAsStringSync('payload');
        final archive = p.join(root.path, 'bundle.tar.gz');
        final output = Directory(p.join(root.path, 'output'))..createSync();
        await tester.runAsync(
          () => ArchiveEngine().run(
            ArchiveRequest(
              'compress',
              archive,
              format: 'tar.gz',
              inputs: [source.path],
            ),
          ),
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'loadSettings') return {'autoUnpackTar': enabled};
          if (call.method == 'takeFinderRequests') {
            return [
              {
                'action': finder ? 'extractTo' : 'open',
                'paths': [archive],
              },
            ];
          }
          if (call.method == 'chooseFolder') return [output.path];
          if (call.method == 'finderChooseFolder') return output.path;
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.pumpWidget(const F7ZipApp());
        if (!finder) {
          await _until(
            tester,
            () =>
                find.text('payload.txt').evaluate().isNotEmpty ||
                find.text('archive.tar').evaluate().isNotEmpty,
          );
          expect(
            find.text(enabled ? 'payload.txt' : 'archive.tar'),
            findsWidgets,
          );
          await tester.tap(find.text('解压到…'));
        }
        await _until(
          tester,
          () => find.textContaining('解压完成 ·').evaluate().isNotEmpty,
        );
        final destination = finder
            ? output
            : Directory(p.join(output.path, 'bundle'));
        final files = destination.listSync();
        expect(files, hasLength(1));
        expect(
          p.basename(files.single.path),
          enabled ? 'payload.txt' : 'archive.tar',
        );
        if (enabled) {
          expect(File(files.single.path).readAsStringSync(), 'payload');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('TAR 复合解包默认开启，关闭后保存并重启恢复', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map<dynamic, dynamic> persisted = {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadSettings') return persisted;
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
    final toggle = find.byKey(const ValueKey('autoUnpackTar'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(persisted['autoUnpackTar'], isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 200 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(ready(), isTrue);
}
