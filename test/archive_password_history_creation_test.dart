import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/archive_password_history.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final scenario in [
    'encrypted',
    'volumes',
    'plain',
    'cancel',
    'existing',
  ]) {
    testWidgets('创建入口密码历史 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync(
        'f7zip-created-password-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final input = File(p.join(root.path, 'source.txt'))
        ..writeAsStringSync('payload');
      final output = p.join(root.path, 'created.zip');
      if (scenario == 'existing') File(output).writeAsStringSync('original');
      const channel = MethodChannel('sevenzip/desktop');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'chooseInputs') return [input.path];
        if (call.method == 'saveArchive') {
          return scenario == 'cancel' ? null : output;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建压缩包').last);
      await tester.pumpAndSettle();
      String password = '';
      if (scenario != 'plain') {
        await tester.ensureVisible(find.byTooltip('生成随机密码'));
        await tester.tap(find.byTooltip('生成随机密码'));
        await tester.pumpAndSettle();
        password = tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('generatedPassword')),
            )
            .textSpan!
            .toPlainText();
        await tester.tap(find.text('使用此密码'));
        await tester.pumpAndSettle();
      }
      if (scenario == 'volumes') {
        await tester.ensureVisible(find.byKey(const ValueKey('volumeSize')));
        await tester.tap(find.byKey(const ValueKey('volumeSize')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10 MiB').last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('选择保存位置'));
      final expectedPath = scenario == 'volumes' ? '$output.001' : output;
      if (scenario == 'cancel') {
        await tester.pumpAndSettle();
        expect(File(output).existsSync(), isFalse);
      } else {
        for (var attempt = 0; attempt < 150; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (scenario == 'existing'
              ? find.text('操作未完成').evaluate().isNotEmpty
              : find
                    .byKey(const ValueKey('row:source.txt'))
                    .evaluate()
                    .isNotEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
        expect(File(expectedPath).existsSync(), isTrue);
      }
      final loading = ArchivePasswordHistory.load();
      await tester.pump();
      final records = await loading;
      if (scenario == 'encrypted' || scenario == 'volumes') {
        expect(records, hasLength(1));
        expect(records.single.path, expectedPath);
        expect(records.single.password, password);
        // 用保存的密码实际解码并校验刚创建的加密归档。
        await tester.runAsync(() async {
          await ArchiveEngine().run(
            ArchiveRequest(
              'test',
              expectedPath,
              password: records.single.password,
            ),
          );
        });
      } else {
        expect(records, isEmpty);
      }
      if (scenario == 'existing') {
        expect(File(output).readAsStringSync(), 'original');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
