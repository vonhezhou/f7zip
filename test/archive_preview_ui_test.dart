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
    'close',
    'failure',
    'encrypted',
    'oversized',
    'limit',
    'dispose',
    'cancel',
  ]) {
    testWidgets('内置预览生命周期 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-preview-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, 'hello.txt'));
      source.writeAsBytesSync(
        scenario == 'oversized'
            ? List.filled(4 * 1024 * 1024 + 1, 65)
            : 'preview text'.codeUnits,
      );
      final archive = p.join(root.path, 'bundle.zip');
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest(
            'compress',
            archive,
            inputs: [source.path],
            password: ['encrypted', 'cancel'].contains(scenario)
                ? 'secret'
                : '',
          ),
        ),
      );
      final shown = <Map>[];
      final directories = <String>[];
      final created = Completer<String>();
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
          case 'createArchivePreviewDirectory':
            final directory = Directory(
              p.join(root.path, 'preview-${directories.length}'),
            )..createSync();
            directories.add(directory.path);
            return scenario == 'dispose' ? created.future : directory.path;
          case 'discardArchivePreviewDirectory':
            final directory = Directory(call.arguments as String);
            if (directory.existsSync()) directory.deleteSync(recursive: true);
            return null;
          case 'showArchivePreview':
            if (scenario == 'failure') {
              throw PlatformException(code: 'preview', message: '无法预览');
            }
            final arguments = call.arguments as Map;
            expectSync(
              File(arguments['path'] as String).readAsStringSync(),
              'preview text',
            );
            expectSync(arguments['kind'], 'text');
            shown.add(arguments);
            return null;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await _until(
        tester,
        () => find.byKey(const ValueKey('row:hello.txt')).evaluate().isNotEmpty,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('row:hello.txt')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pump();
      var finished = false;
      unawaited(
        _native('archiveCommand', 'preview').then((_) => finished = true),
      );
      if (scenario == 'encrypted' || scenario == 'cancel') {
        for (final password in ['bad', 'secret']) {
          await _until(tester, () => find.text('压缩包密码').evaluate().isNotEmpty);
          if (scenario == 'cancel' && password == 'secret') {
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            break;
          }
          await tester.enterText(find.byType(TextField).last, password);
          await tester.tap(find.text('确定'));
          await tester.pumpAndSettle();
        }
      }
      if (scenario == 'dispose') {
        await _until(tester, () => directories.isNotEmpty);
        await tester.pumpWidget(const SizedBox());
        created.complete(directories.single);
        await _until(tester, () => finished);
      } else if (scenario == 'cancel') {
        await _until(tester, () => finished);
        expect(shown, isEmpty);
      } else if (scenario == 'failure' || scenario == 'oversized') {
        await _until(
          tester,
          () => find.byType(AlertDialog).evaluate().isNotEmpty,
        );
        await tester.tap(find.text('知道了').last);
        await _until(tester, () => finished);
        expect(shown, isEmpty);
      } else {
        await _until(tester, () => finished);
        expect(shown.length, 1);
        if (scenario == 'limit') {
          finished = false;
          unawaited(
            _native('archiveCommand', 'preview').then((_) => finished = true),
          );
          await _until(tester, () => finished);
          expect(shown.length, 2);
          unawaited(_native('archiveCommand', 'preview'));
          await _until(
            tester,
            () => find.byType(AlertDialog).evaluate().isNotEmpty,
          );
          expect(directories.length, 2);
          await tester.tap(find.text('知道了').last);
        }
        for (final arguments in shown) {
          await _native('archivePreviewClosed', {'id': arguments['id']});
        }
      }
      await tester.pumpWidget(const SizedBox());
      await _until(
        tester,
        () => directories.every((path) => !Directory(path).existsSync()),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}

Future<dynamic> _native(String method, dynamic arguments) {
  final completer = Completer<dynamic>();
  const codec = StandardMethodCodec();
  unawaited(
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'sevenzip/desktop',
          codec.encodeMethodCall(MethodCall(method, arguments)),
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
