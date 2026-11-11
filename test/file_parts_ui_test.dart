import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final scenario in ['roundTrip', 'cancelSplit', 'cancelJoin', 'retry']) {
    testWidgets('普通文件分割合并真实入口 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-file-parts-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, '中文😀.bin'))
        ..writeAsBytesSync(List<int>.generate(2300000, (index) => index % 256));
      final prefix = p.join(root.path, 'parts');
      final first = File('$prefix.001');
      final manifest = File('$prefix.f7zip-parts.json');
      final output = File(p.join(root.path, 'joined.bin'));
      var inputPath = source.path;
      var outputPath = prefix;
      var saves = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('sevenzip/desktop');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openArchive') return [inputPath];
        if (call.method == 'saveArchive') {
          saves++;
          return outputPath;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('分割普通文件…'));
      await tester.tap(find.text('分割普通文件…'));
      await _until(
        tester,
        () => find.byKey(const ValueKey('filePartSize')).evaluate().isNotEmpty,
      );
      if (scenario == 'cancelSplit') {
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(saves, 0);
        expect(first.existsSync(), isFalse);
      } else {
        final field = find.byKey(const ValueKey('filePartSize'));
        for (final invalid in ['0', '1.5', '2097152']) {
          await tester.enterText(field, invalid);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, '选择输出名称'),
                )
                .onPressed,
            isNull,
          );
        }
        await tester.enterText(field, '1');
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择输出名称'));
        await _until(
          tester,
          () => find.text('文件分割完成 · 3 片，已保存校验清单').evaluate().isNotEmpty,
        );
        final metadata = jsonDecode(manifest.readAsStringSync()) as Map;
        expect(
          metadata['sha256'],
          sha256.convert(source.readAsBytesSync()).toString(),
        );
        expect(first.existsSync(), isTrue);
        expect(Directory(root.path).listSync().whereType<Directory>(), isEmpty);
        inputPath = first.path;
        outputPath = output.path;
        List<int>? saved;
        if (scenario == 'retry') {
          saved = first.readAsBytesSync();
          final corrupted = List<int>.of(saved)..[0] ^= 1;
          first.writeAsBytesSync(corrupted);
        }
        unawaited(_command('joinFile'));
        await _until(tester, () => find.text('合并普通文件').evaluate().isNotEmpty);
        if (scenario == 'cancelJoin') {
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(saves, 1);
          expect(output.existsSync(), isFalse);
        } else {
          await tester.tap(find.text('确定'));
          if (scenario == 'retry') {
            await _until(tester, () => find.text('知道了').evaluate().isNotEmpty);
            expect(find.textContaining('分片 SHA-256 不一致'), findsOneWidget);
            expect(output.existsSync(), isFalse);
            expect(
              Directory(root.path).listSync().whereType<Directory>(),
              isEmpty,
            );
            first.writeAsBytesSync(saved!);
            await tester.tap(find.text('知道了'));
            await tester.pumpAndSettle();
            unawaited(_command('joinFile'));
            await _until(
              tester,
              () => find.text('合并普通文件').evaluate().isNotEmpty,
            );
            await tester.tap(find.text('确定'));
          }
          await _until(
            tester,
            () => find.text('文件合并完成 · SHA-256 一致').evaluate().isNotEmpty,
          );
          expect(output.readAsBytesSync(), source.readAsBytesSync());
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
