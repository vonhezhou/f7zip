import 'dart:async';
import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  for (final scenario in [
    'return',
    'quick',
    'parentMissing',
    'changedParent',
    'newRoot',
    'close',
    'dispose',
    'failure',
    'password',
    'cancel',
    'changedSource',
    'depth',
  ]) {
    testWidgets('嵌套归档真实引擎与窗口流程 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-nested-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final data = File(p.join(root.path, 'hello.txt'))
        ..writeAsStringSync('nested data');
      final source = Directory(p.join(root.path, 'folder'))..createSync();
      final inner = p.join(
        source.path,
        scenario == 'password' ? 'inner.7z' : 'inner.zip',
      );
      final archive = p.join(root.path, 'outer.zip');
      final directories = <String>[];
      final remembered = <String>[];
      Map? commands;
      await tester.runAsync(() async {
        await ArchiveEngine().run(
          ArchiveRequest(
            'compress',
            inner,
            format: scenario == 'password' ? '7z' : 'zip',
            password: scenario == 'password' ? 'inner-secret' : '',
            inputs: [data.path],
          ),
        );
        if (scenario == 'failure') {
          File(inner).writeAsStringSync('broken archive');
        }
        if (scenario == 'depth') {
          var child = data.path;
          for (var index = 9; index >= 1; index--) {
            final next = p.join(root.path, 'level$index.zip');
            await ArchiveEngine().run(
              ArchiveRequest('compress', next, inputs: [child]),
            );
            child = next;
          }
          File(child).copySync(inner);
        }
        await ArchiveEngine().run(
          ArchiveRequest(
            'compress',
            archive,
            inputs: [source.path],
            password: ['password', 'cancel'].contains(scenario)
                ? 'outer-secret'
                : '',
          ),
        );
      });
      final output = Directory(p.join(root.path, 'output'))..createSync();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'takeFinderRequests':
            return [
              {
                'action': 'open',
                'paths': [archive],
              },
            ];
          case 'createNestedArchiveDirectory':
            final directory = Directory(
              p.join(root.path, 'nested-${directories.length}'),
            )..createSync();
            directories.add(directory.path);
            return directory.path;
          case 'discardNestedArchiveDirectory':
            final directory = Directory(call.arguments as String);
            if (directory.existsSync()) directory.deleteSync(recursive: true);
            return null;
          case 'rememberArchive':
            remembered.add(call.arguments as String);
            return null;
          case 'updateCommands':
            commands = call.arguments as Map;
            return null;
          case 'chooseFolder':
            return [output.path];
          case 'openArchive':
            return [archive];
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await _until(
        tester,
        () => find.byKey(const ValueKey('row:folder')).evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('row:folder')));
      await tester.pumpAndSettle();
      if (scenario == 'return') {
        await tester.enterText(find.byType(TextField), 'inner');
        await tester.pumpAndSettle();
      }
      final innerName = p.basename(inner);
      await _select(tester, 'folder/$innerName');
      if (scenario == 'changedSource') {
        File(archive).writeAsBytesSync([...File(archive).readAsBytesSync(), 0]);
      }
      var finished = false;
      unawaited(_native('nested').then((_) => finished = true));
      if (scenario == 'password' || scenario == 'cancel') {
        for (final password in [
          'bad',
          'outer-secret',
          if (scenario == 'password') 'inner-secret',
        ]) {
          await _until(tester, () => find.text('压缩包密码').evaluate().isNotEmpty);
          if (scenario == 'cancel' && password == 'outer-secret') {
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            break;
          }
          await tester.enterText(find.byType(TextField).last, password);
          await tester.tap(find.text('确定'));
          await tester.pumpAndSettle();
        }
      }
      if (scenario == 'failure') {
        await _until(tester, () => find.text('压缩包密码').evaluate().isNotEmpty);
        await tester.tap(find.text('取消'));
      }
      if (scenario == 'changedSource') {
        await _until(tester, () => find.text('知道了').evaluate().isNotEmpty);
        expect(find.textContaining('已变化'), findsWidgets);
        await tester.tap(find.text('知道了'));
      }
      await _until(tester, () => finished);
      if (['cancel', 'failure', 'changedSource'].contains(scenario)) {
        expect(find.byKey(ValueKey('row:folder/$innerName')), findsOneWidget);
        expect(
          directories.every((path) => !Directory(path).existsSync()),
          isTrue,
        );
      } else {
        expect(find.text('子包 · 只读浏览'), findsOneWidget);
        expect(commands!['add'], isFalse);
        expect(commands!['edit'], isFalse);
        expect(commands!['parentArchive'], isTrue);
        expect(remembered, [archive]);
        if (scenario == 'depth') {
          for (var index = 2; index <= 8; index++) {
            await _select(tester, 'level$index.zip');
            finished = false;
            unawaited(_native('nested').then((_) => finished = true));
            await _until(tester, () => finished);
          }
          await _select(tester, 'level9.zip');
          unawaited(_native('nested'));
          await _until(tester, () => find.text('知道了').evaluate().isNotEmpty);
          expect(directories.length, 8);
          expect(find.textContaining('最多进入八层'), findsOneWidget);
          await tester.tap(find.text('知道了'));
          for (var index = 0; index < 8; index++) {
            finished = false;
            unawaited(_native('parentArchive').then((_) => finished = true));
            await _until(tester, () => finished);
          }
        } else if (scenario == 'parentMissing') {
          File(archive).deleteSync();
          finished = false;
          unawaited(_native('parentArchive').then((_) => finished = true));
          await _until(tester, () => find.text('知道了').evaluate().isNotEmpty);
          await tester.tap(find.text('知道了'));
          await _until(tester, () => finished);
          expect(find.byKey(const ValueKey('row:hello.txt')), findsOneWidget);
          expect(Directory(directories.single).existsSync(), isTrue);
          await _native('close');
        } else if (scenario == 'close') {
          await _native('close');
        } else if (scenario == 'dispose') {
          await tester.pumpWidget(const SizedBox());
        } else if (scenario == 'newRoot') {
          finished = false;
          unawaited(_native('open').then((_) => finished = true));
          await _until(tester, () => finished);
        } else {
          expect(find.byKey(const ValueKey('row:hello.txt')), findsOneWidget);
          if (scenario == 'return' || scenario == 'quick') {
            if (scenario == 'quick') {
              await tester.tap(find.byTooltip('更多操作'));
              await tester.pumpAndSettle();
              await tester.tap(find.widgetWithText(SubmenuButton, '解压'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('快速解压到同级目录'));
              await _until(
                tester,
                () =>
                    File(p.join(output.path, 'inner', 'hello.txt'))
                        .existsSync(),
              );
            } else {
              finished = false;
              unawaited(_native('extract').then((_) => finished = true));
              await _until(tester, () => finished);
            }
            expect(
              File(p.join(output.path, 'inner', 'hello.txt'))
                  .readAsStringSync(),
              'nested data',
            );
          }
          if (scenario == 'changedParent') {
            final added = File(p.join(source.path, 'new.txt'))
              ..writeAsStringSync('new');
            await tester.runAsync(
              () => ArchiveEngine().run(
                ArchiveRequest(
                  'compress',
                  p.join(root.path, 'new.zip'),
                  inputs: [source.path],
                ),
              ),
            );
            File(p.join(root.path, 'new.zip')).copySync(archive);
            expect(added.existsSync(), isTrue);
          }
          finished = false;
          unawaited(_native('parentArchive').then((_) => finished = true));
          await _until(tester, () => finished);
          expect(find.byKey(ValueKey('row:folder/$innerName')), findsOneWidget);
          expect(commands!['add'], isTrue);
          expect(commands!['parentArchive'], isFalse);
          if (scenario == 'return') {
            expect(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
              'inner',
            );
          }
          if (scenario == 'changedParent') {
            expect(
              find.byKey(const ValueKey('row:folder/new.txt')),
              findsOneWidget,
            );
          }
        }
        await _until(
          tester,
          () => directories.every((path) => !Directory(path).existsSync()),
        );
        if (scenario == 'return') {
          expect(
            File(p.join(output.path, 'inner', 'hello.txt')).readAsStringSync(),
            'nested data',
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _select(WidgetTester tester, String path) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(ValueKey('row:$path')),
      matching: find.byType(Checkbox),
    ),
  );
  await tester.pumpAndSettle();
}

Future<dynamic> _native(String command) {
  final completer = Completer<dynamic>();
  const codec = StandardMethodCodec();
  unawaited(
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'sevenzip/desktop',
          codec.encodeMethodCall(MethodCall('archiveCommand', command)),
          (data) {
            try {
              completer.complete(codec.decodeEnvelope(data!));
            } catch (error, stack) {
              completer.completeError(error, stack);
            }
          },
        ),
  );
  return completer.future;
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
