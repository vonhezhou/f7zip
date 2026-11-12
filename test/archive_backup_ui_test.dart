import 'dart:async';
import 'dart:io';

import 'package:f7zip/archive_backup.dart';
import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  for (final scenario in ['restore', 'cancel', 'empty']) {
    testWidgets('原包备份与删除恢复 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-backup-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final data = File(p.join(root.path, 'hello.txt'))
        ..writeAsStringSync('original data');
      final archive = p.join(root.path, 'sample.zip');
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest('compress', archive, inputs: [data.path]),
        ),
      );
      final original = File(archive).readAsBytesSync();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
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
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await _until(
        tester,
        () => find.byKey(const ValueKey('row:hello.txt')).evaluate().isNotEmpty,
      );
      if (scenario != 'empty') {
        await _select(tester, 'hello.txt');
        var finished = false;
        unawaited(_native('remove').then((_) => finished = true));
        await _until(tester, () => find.text('从压缩包删除').evaluate().isNotEmpty);
        await tester.tap(find.text('确定'));
        await _until(tester, () => finished);
        expect(find.byKey(const ValueKey('row:hello.txt')), findsNothing);
        final backups = await tester.runAsync(
          () => findArchiveBackups(archive),
        );
        expect(backups, hasLength(1));
        expect(File(backups!.single.path).readAsBytesSync(), original);
      }
      var restored = false;
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SubmenuButton, '编辑压缩包'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('恢复原包备份…'));
      await tester.tap(find.text('恢复原包备份…'));
      await _until(
        tester,
        () => find
            .text(scenario == 'empty' ? '知道了' : '恢复原包备份')
            .evaluate()
            .isNotEmpty,
      );
      if (scenario == 'empty') {
        expect(find.textContaining('还没有原包备份'), findsOneWidget);
        await tester.tap(find.text('知道了'));
      } else if (scenario == 'cancel') {
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('row:hello.txt')), findsNothing);
      } else {
        await tester.tap(find.byType(ListTile).last);
        await _until(tester, () => find.text('恢复整个压缩包？').evaluate().isNotEmpty);
        await tester.tap(find.text('确定'));
        await _until(
          tester,
          () =>
              find.byKey(const ValueKey('row:hello.txt')).evaluate().isNotEmpty,
        );
        restored = true;
        expect(File(archive).readAsBytesSync(), original);
        final backups = await tester.runAsync(
          () => findArchiveBackups(archive),
        );
        expect(backups, hasLength(2));
      }
      expect(restored, scenario == 'restore');
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
