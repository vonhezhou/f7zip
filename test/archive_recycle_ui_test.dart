import 'dart:async';
import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  for (final scenario in ['success', 'cancel', 'skip', 'failure']) {
    testWidgets('解压后回收源包 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-trash-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final data = File(p.join(root.path, 'hello.txt'))
        ..writeAsStringSync('original data');
      final archive = p.join(root.path, '${p.basename(root.path)}.zip');
      final output = Directory(p.join(root.path, 'output'))..createSync();
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest('compress', archive, inputs: [data.path]),
        ),
      );
      final original = File(archive).readAsBytesSync();
      final trashed = File(
        p.join(Platform.environment['HOME']!, '.Trash', p.basename(archive)),
      );
      addTearDown(() {
        if (trashed.existsSync() &&
            listEquals(trashed.readAsBytesSync(), original)) {
          trashed.deleteSync();
        }
      });
      final destination = Directory(
        p.join(output.path, p.basenameWithoutExtension(archive)),
      );
      if (scenario == 'skip') {
        destination.createSync();
        File(p.join(destination.path, 'hello.txt'))
            .writeAsStringSync('existing');
      }
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
        if (call.method == 'chooseFolder') return [output.path];
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await _until(
        tester,
        () => find.byKey(const ValueKey('row:hello.txt')).evaluate().isNotEmpty,
      );
      var finished = false;
      unawaited(_native('extractTrash').then((_) => finished = true));
      await _until(
        tester,
        () => find.text('解压成功后移至废纸篓？').evaluate().isNotEmpty,
      );
      if (scenario == 'cancel') {
        await tester.tap(find.text('取消'));
      } else {
        if (scenario == 'failure') {
          File(archive).writeAsStringSync('corrupt archive');
        }
        await tester.tap(find.text('确定'));
        if (scenario == 'skip') {
          await _until(
            tester,
            () => find.text('解压目标存在同名项目').evaluate().isNotEmpty,
          );
          await tester.tap(find.byKey(const ValueKey('extractionPolicy:skip')));
        }
      }
      if (scenario == 'failure') {
        await _until(
          tester,
          () => finished || find.text('知道了').evaluate().isNotEmpty,
        );
        if (!finished) await tester.tap(find.text('知道了'));
      }
      await _until(tester, () => finished);
      if (scenario == 'success') {
        expect(File(archive).existsSync(), isFalse);
        expect(
          File(p.join(destination.path, 'hello.txt')).readAsStringSync(),
          'original data',
        );
        expect(find.textContaining('原包已移至废纸篓'), findsOneWidget);
      } else {
        expect(File(archive).existsSync(), isTrue);
        if (scenario == 'skip') {
          expect(
            File(p.join(destination.path, 'hello.txt')).readAsStringSync(),
            'existing',
          );
        }
        if (scenario == 'cancel') expect(destination.existsSync(), isFalse);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
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
