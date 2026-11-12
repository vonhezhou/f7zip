import 'dart:async';
import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final scenario in ['success', 'cancel', 'retry', 'password']) {
    testWidgets('ZIP 修复真实入口 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-repair-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, '中文😀.txt'))
        ..writeAsStringSync('recover this payload');
      final archive = File(p.join(root.path, 'broken.zip'));
      final output = File(p.join(root.path, 'repaired.zip'));
      final password = scenario == 'password' ? 'secret' : '';
      await tester.runAsync(() async {
        await ArchiveEngine().run(
          ArchiveRequest(
            'compress',
            archive.path,
            inputs: [source.path],
            password: password,
          ),
        );
      });
      final bytes = archive.readAsBytesSync();
      var central = -1;
      for (var index = 0; index + 4 <= bytes.length; index++) {
        if (bytes[index] == 80 &&
            bytes[index + 1] == 75 &&
            bytes[index + 2] == 1 &&
            bytes[index + 3] == 2) {
          central = index;
          break;
        }
      }
      expect(central, greaterThan(0));
      archive.writeAsBytesSync(bytes.sublist(0, central));
      final before = archive.readAsBytesSync();
      if (scenario == 'retry') output.writeAsStringSync('keep existing');
      var saves = 0;
      const channel = MethodChannel('sevenzip/desktop');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openArchive') return [archive.path];
        if (call.method == 'saveArchive') {
          saves++;
          return output.path;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SubmenuButton, '工具'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('修复 ZIP…'));
      await tester.tap(find.text('修复 ZIP…'));
      await _until(
        tester,
        () => find.text('修复 ZIP 到新文件').evaluate().isNotEmpty,
      );
      expect(find.textContaining('ZIP64 暂不支持'), findsOneWidget);
      if (scenario == 'cancel') {
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(saves, 0);
        expect(output.existsSync(), isFalse);
      } else {
        await tester.tap(find.text('确定'));
        if (scenario == 'retry') {
          await _until(tester, () => find.text('知道了').evaluate().isNotEmpty);
          expect(find.textContaining('修复目标已存在'), findsOneWidget);
          expect(output.readAsStringSync(), 'keep existing');
          output.deleteSync();
          await tester.tap(find.text('知道了'));
          await tester.pumpAndSettle();
          unawaited(_command());
          await _until(
            tester,
            () => find.text('修复 ZIP 到新文件').evaluate().isNotEmpty,
          );
          await tester.tap(find.text('确定'));
        }
        if (scenario == 'password') {
          await _until(tester, () => find.text('压缩包密码').evaluate().isNotEmpty);
          await tester.enterText(find.byType(TextField).last, 'secret');
          await tester.tap(find.text('确定'));
        }
        await _until(
          tester,
          () => find.text('ZIP 修复完成 · 恢复 1 项，跳过 0 项').evaluate().isNotEmpty,
        );
        expect(output.existsSync(), isTrue);
        await tester.runAsync(() async {
          await ArchiveEngine().run(
            ArchiveRequest('test', output.path, password: password),
          );
          final destination = p.join(root.path, 'verified');
          await ArchiveEngine().run(
            ArchiveRequest(
              'extract',
              output.path,
              destination: destination,
              password: password,
            ),
          );
          expect(
            File(p.join(destination, p.basename(source.path)))
                .readAsBytesSync(),
            source.readAsBytesSync(),
          );
        });
      }
      expect(archive.readAsBytesSync(), before);
      expect(
        root.listSync().whereType<Directory>(),
        everyElement(
          isA<Directory>().having(
            (directory) => p.basename(directory.path),
            'name',
            'verified',
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}

Future<dynamic> _command() {
  final completer = Completer<dynamic>();
  const codec = StandardMethodCodec();
  unawaited(
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'sevenzip/desktop',
          codec.encodeMethodCall(
            const MethodCall('archiveCommand', 'repairZip'),
          ),
          (data) => completer.complete(codec.decodeEnvelope(data!)),
        ),
  );
  return completer.future;
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
