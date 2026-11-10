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
    'single',
    'directory',
    'multiple',
    'cancel',
    'changed',
    'conflict',
    'encrypted',
    'queueBusy',
  ]) {
    testWidgets('文件名拖放经原生承诺消息处理 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-drag-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = Directory(p.join(root.path, 'source'))..createSync();
      File(p.join(source.path, 'one.txt')).writeAsStringSync('one');
      File(p.join(source.path, 'two.txt')).writeAsStringSync('two');
      final archive = p.join(root.path, 'bundle.zip');
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest(
            'compress',
            archive,
            inputs: [source.path],
            password: scenario == 'encrypted' ? 'secret' : '',
          ),
        ),
      );
      final output = Directory(p.join(root.path, 'output'))..createSync();
      Map<dynamic, dynamic>? drag;
      var passwords = 0;
      final queueChoice = Completer<String?>();
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
        if (call.method == 'finderChooseFolder' && scenario == 'queueBusy') {
          return queueChoice.future;
        }
        if (call.method == 'startArchiveDrag') drag = call.arguments as Map;
        if (call.method == 'finderPassword') {
          return ++passwords == 1 ? 'bad' : 'secret';
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await _until(
        tester,
        () => find.byKey(const ValueKey('row:source')).evaluate().isNotEmpty,
      );
      if (scenario != 'directory') {
        await tester.tap(find.byKey(const ValueKey('row:source')));
        await tester.pumpAndSettle();
      }
      if (scenario == 'multiple') {
        for (final name in ['one.txt', 'two.txt']) {
          await tester.tap(
            find.descendant(
              of: find.byKey(ValueKey('row:source/$name')),
              matching: find.byType(Checkbox),
            ),
          );
          await tester.pump();
        }
      }
      await tester.drag(
        find.byKey(
          ValueKey(
            scenario == 'directory' ? 'drag:source' : 'drag:source/one.txt',
          ),
        ),
        const Offset(100, 0),
      );
      await tester.pumpAndSettle();
      expect(drag, isNotNull);
      expect(output.listSync(), isEmpty);
      final items = (drag!['items'] as List).cast<Map>();
      expect(items.length, scenario == 'multiple' ? 2 : 1);
      await _native('archiveDragEnded', {
        'session': drag!['session'],
        'cancelled': scenario == 'cancel',
      });
      if (scenario == 'conflict') {
        File(p.join(output.path, items.single['name'] as String))
            .writeAsStringSync('keep');
      }
      if (scenario == 'changed') {
        File(archive).writeAsBytesSync([...File(archive).readAsBytesSync(), 0]);
      }
      if (scenario == 'queueBusy') {
        await _native('finderRequest', {
          'action': 'extractTo',
          'paths': <String>[],
        });
        await tester.pump();
      }
      final results = <Object>[];
      for (final item in items) {
        unawaited(
          _native('writeArchivePromise', {
            'session': drag!['session'],
            'item': item['id'],
            'destination': p.join(output.path, item['name'] as String),
          }).then<void>(
            (value) => results.add(value as Object),
            onError: (Object error, StackTrace stack) => results.add(error),
          ),
        );
      }
      await _until(tester, () => results.length == items.length);
      if (scenario == 'queueBusy') {
        expect(results.single, isA<PlatformException>());
        expect((results.single as PlatformException).code, 'busy');
        expect(output.listSync(), isEmpty);
        queueChoice.complete(null);
        await tester.pumpAndSettle();
        Object? retried;
        unawaited(
          _native('writeArchivePromise', {
            'session': drag!['session'],
            'item': items.single['id'],
            'destination': p.join(output.path, items.single['name'] as String),
          }).then<void>(
            (value) => retried = value as Object,
            onError: (Object error, StackTrace stack) => retried = error,
          ),
        );
        await _until(tester, () => retried != null);
        expect(retried, {'ok': true});
        expect(
          File(p.join(output.path, items.single['name'] as String))
              .readAsStringSync(),
          'one',
        );
      } else if (scenario == 'cancel' || scenario == 'changed') {
        expect(results.every((value) => value is PlatformException), isTrue);
        expect(output.listSync(), isEmpty);
      } else if (scenario == 'conflict') {
        expect(results.single, isA<PlatformException>());
        expect(
          File(p.join(output.path, items.single['name'] as String))
              .readAsStringSync(),
          'keep',
        );
        drag = null;
        await tester.drag(
          find.byKey(const ValueKey('drag:source/one.txt')),
          const Offset(100, 0),
        );
        await tester.pumpAndSettle();
        expect(drag, isNotNull);
        await _native('archiveDragEnded', {
          'session': drag!['session'],
          'cancelled': false,
        });
        Object? retried;
        unawaited(
          _native('writeArchivePromise', {
            'session': drag!['session'],
            'item': '0',
            'destination': p.join(output.path, 'retry.txt'),
          }).then<void>(
            (value) => retried = value as Object,
            onError: (Object error, StackTrace stack) => retried = error,
          ),
        );
        await _until(tester, () => retried != null);
        expect(retried, {'ok': true});
        expect(
          File(p.join(output.path, 'retry.txt')).readAsStringSync(),
          'one',
        );
      } else {
        expect(results, everyElement({'ok': true}));
        for (final item in items) {
          final path = p.join(output.path, item['name'] as String);
          if (scenario == 'directory') {
            expect(item['directory'], isTrue);
            expect(File(p.join(path, 'one.txt')).readAsStringSync(), 'one');
            expect(File(p.join(path, 'two.txt')).readAsStringSync(), 'two');
          } else {
            expect(
              File(path).readAsStringSync(),
              item['name'] == 'one.txt' ? 'one' : 'two',
            );
          }
        }
        if (scenario == 'encrypted') expect(passwords, 2);
      }
      expect(
        output.listSync().where(
          (entry) => p.basename(entry.path).startsWith('.f7zip-'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Future<dynamic> _native(String method, Map<String, dynamic> arguments) {
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
