import 'dart:async';
import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final scenario in ['save', 'cancel', 'readonly']) {
    testWidgets('注释属性与编辑真实引擎流程 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-comments-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, 'data.txt'))
        ..writeAsStringSync('preserve data');
      final format = scenario == 'readonly' ? '7z' : 'zip';
      final archive = p.join(root.path, 'sample.$format');
      await tester.runAsync(() async {
        final engine = ArchiveEngine();
        await engine.run(
          ArchiveRequest(
            'compress',
            archive,
            format: format,
            inputs: [source.path],
          ),
        );
        if (scenario != 'readonly') {
          final listed = await engine.run(ArchiveRequest('list', archive));
          await engine.run(
            ArchiveRequest(
              'fileComment',
              archive,
              itemPath: 'data.txt',
              expectedVersion: listed['version'] as String,
              destination: '原始文件注释',
            ),
          );
        }
      });
      final before = File(archive).readAsBytesSync();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('sevenzip/desktop');
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
        () => find.byKey(const ValueKey('row:data.txt')).evaluate().isNotEmpty,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('row:data.txt')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      if (scenario == 'readonly') {
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        final item = tester.widget<PopupMenuItem<String>>(
          find.widgetWithText(PopupMenuItem<String>, '编辑文件注释…'),
        );
        expect(item.enabled, isFalse);
        await tester.tapAt(const Offset(20, 300));
        await tester.pumpAndSettle();
      } else {
        var finished = false;
        unawaited(_command('properties').then((_) => finished = true));
        await _until(tester, () => find.text('原始文件注释').evaluate().isNotEmpty);
        await tester.tap(find.text('关闭'));
        await _until(tester, () => finished);
        unawaited(_command('fileComment'));
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('archiveCommentText'))
              .evaluate()
              .isNotEmpty,
        );
        final input = find.byKey(const ValueKey('archiveCommentText'));
        expect(tester.widget<TextField>(input).controller!.text, '原始文件注释');
        await tester.enterText(input, '中' * 5462);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '保存注释'))
              .onPressed,
          isNull,
        );
        await tester.enterText(input, '新的中文注释 😀\n下一行');
        await tester.pumpAndSettle();
        await tester.tap(find.text(scenario == 'cancel' ? '取消' : '保存注释'));
        if (scenario == 'save') {
          await _until(
            tester,
            () => find.text('编辑文件注释完成').evaluate().isNotEmpty,
          );
          unawaited(_command('archiveComment'));
          await _until(
            tester,
            () => find
                .byKey(const ValueKey('archiveCommentText'))
                .evaluate()
                .isNotEmpty,
          );
          await tester.enterText(
            find.byKey(const ValueKey('archiveCommentText')),
            '新的归档注释 😀',
          );
          await tester.tap(find.text('保存注释'));
          await _until(
            tester,
            () => find.text('编辑归档注释完成').evaluate().isNotEmpty,
          );
          final listed = await tester.runAsync(
            () => ArchiveEngine().run(ArchiveRequest('list', archive)),
          );
          expect(listed!['comment'], '新的归档注释 😀');
          expect((listed['items'] as List).single['comment'], '新的中文注释 😀\n下一行');
        } else {
          await tester.pumpAndSettle();
          expect(File(archive).readAsBytesSync(), before);
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}

Future<dynamic> _command(String value) {
  final completer = Completer<dynamic>();
  const codec = StandardMethodCodec();
  unawaited(
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'sevenzip/desktop',
          codec.encodeMethodCall(MethodCall('archiveCommand', value)),
          (data) => completer.complete(codec.decodeEnvelope(data!)),
        ),
  );
  return completer.future;
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(ready(), isTrue);
}
