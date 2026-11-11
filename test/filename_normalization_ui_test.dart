import 'dart:async';
import 'dart:io';

import 'package:f7zip/app_settings.dart';
import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/filename_normalization.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const nfd = 'cafe\u0301.txt';
const nfc = 'caf\u00e9.txt';

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  test('规范化配置兼容旧数据，预设更新与密码重试保留选择', () {
    expect(
      AppSettings.fromJson({}).filenameNormalization,
      FilenameNormalization.preserve,
    );
    expect(
      AppSettings.fromJson({'filenameNormalization': 'invalid'})
          .filenameNormalization,
      FilenameNormalization.preserve,
    );
    for (final mode in FilenameNormalization.values) {
      final settings = AppSettings(filenameNormalization: mode)
          .withCompressionPresets([], '');
      expect(
        AppSettings.fromJson(settings.toJson()).filenameNormalization,
        mode,
      );
      final request = ArchiveRequest(
        'export',
        '/archive',
        filenameNormalization: mode,
        expectedVersion: 'version',
        outputLimit: 4096,
      ).withPassword('retry');
      expect(request.filenameNormalization, mode);
      expect(request.expectedVersion, 'version');
      expect(request.outputLimit, 4096);
    }
  });

  testWidgets('设置选择 NFC 并保存后可重新加载', (tester) async {
    Map<dynamic, dynamic> persisted = {};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'saveSettings') persisted = call.arguments as Map;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  SettingsDialog(initial: AppSettings.fromJson(persisted)),
            ),
            child: const Text('设置'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解压'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filenameNormalization')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NFC · 组合形式').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(persisted['filenameNormalization'], 'nfc');
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解压'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<FilenameNormalization>>(
            find.byKey(const ValueKey('filenameNormalization')),
          )
          .value,
      FilenameNormalization.nfc,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  for (final scenario in [
    'compress',
    'extract',
    'encrypted',
    'finder',
    'batch',
    'preview',
    'drag',
  ]) {
    testWidgets('Unicode 规范化经过真实 UI 与引擎入口 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-unicode-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = Directory(p.join(root.path, 'source'))..createSync();
      final folder = Directory(p.join(source.path, 'cafe\u0301'))..createSync();
      final data = File(p.join(folder.path, nfd))..writeAsStringSync('payload');
      final archive = p.join(root.path, 'archive.zip');
      final created = p.join(root.path, 'created.zip');
      final output = Directory(p.join(root.path, 'output'))..createSync();
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest(
            'compress',
            archive,
            inputs: [scenario == 'drag' ? folder.path : data.path],
            password: scenario == 'encrypted' ? 'secret' : '',
          ),
        ),
      );
      Map? preview;
      Map? drag;
      var candidates = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'loadSettings':
            return {
              'filenameNormalization': 'nfc',
              'autoTryPasswords': scenario == 'encrypted',
            };
          case 'takeFinderRequests':
            return [
              {
                'action': scenario == 'finder' ? 'extractHere' : 'open',
                'paths': [archive],
              },
            ];
          case 'chooseFolder':
            return [output.path];
          case 'chooseArchives':
            return [archive];
          case 'chooseInputs':
            return [data.path];
          case 'saveArchive':
            return created;
          case 'archivePasswordCandidates':
            candidates++;
            return ['wrong', 'secret'];
          case 'createArchivePreviewDirectory':
            final directory = Directory(p.join(output.path, 'preview'))
              ..createSync();
            return directory.path;
          case 'showArchivePreview':
            preview = call.arguments as Map;
            return null;
          case 'discardArchivePreviewDirectory':
            final directory = Directory(call.arguments as String);
            if (directory.existsSync()) directory.deleteSync(recursive: true);
            return null;
          case 'startArchiveDrag':
            drag = call.arguments as Map;
            return null;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      if (scenario == 'finder') {
        await _until(tester, () => File(p.join(root.path, nfc)).existsSync());
        expect(
          Directory(root.path)
              .listSync()
              .whereType<File>()
              .map((file) => p.basename(file.path)),
          contains(nfc),
        );
      } else {
        final row = scenario == 'drag' ? 'cafe\u0301' : nfd;
        await _until(
          tester,
          () => find.byKey(ValueKey('row:$row')).evaluate().isNotEmpty,
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey('row:$row')),
            matching: find.byType(Checkbox),
          ),
        );
        await tester.pump();
        var finished = false;
        if (scenario == 'compress') {
          unawaited(_native('archiveCommand', 'new'));
          await _until(tester, () => find.text('选择保存位置').evaluate().isNotEmpty);
          await tester.tap(find.text('选择保存位置'));
          await _until(
            tester,
            () =>
                File(created).existsSync() &&
                find.byKey(const ValueKey('row:$nfc')).evaluate().isNotEmpty,
          );
          final listing = await tester.runAsync(
            () => ArchiveEngine().run(ArchiveRequest('list', created)),
          );
          expect((listing!['items'] as List).single['path'], nfc);
        } else if (scenario == 'drag') {
          await tester.drag(
            find.byKey(ValueKey('drag:$row')),
            const Offset(100, 0),
          );
          await tester.pumpAndSettle();
          expect(drag, isNotNull);
          await _native('archiveDragEnded', {
            'session': drag!['session'],
            'cancelled': false,
          });
          Object? result;
          unawaited(
            _native('writeArchivePromise', {
              'session': drag!['session'],
              'item': ((drag!['items'] as List).single as Map)['id'],
              'destination': p.join(output.path, 'exported'),
            }).then<void>(
              (value) => result = value as Object,
              onError: (Object error, StackTrace stack) => result = error,
            ),
          );
          await _until(tester, () => result != null);
          expect(result, {'ok': true});
          expect(
            Directory(p.join(output.path, 'exported'))
                .listSync()
                .map((entry) => p.basename(entry.path)),
            [nfc],
          );
        } else {
          unawaited(
            _native(
              'archiveCommand',
              scenario == 'preview'
                  ? 'preview'
                  : scenario == 'batch'
                  ? 'batchExtract'
                  : 'extract',
            ).then((_) => finished = true),
          );
          await _until(
            tester,
            () => scenario == 'preview'
                ? preview != null
                : File(p.join(output.path, 'archive', nfc)).existsSync(),
          );
          if (scenario == 'preview') {
            expect(
              File(preview!['path'] as String).readAsStringSync(),
              'payload',
            );
          }
          if (scenario != 'preview') {
            expect(
              Directory(p.join(output.path, 'archive'))
                  .listSync()
                  .map((entry) => p.basename(entry.path)),
              [nfc],
            );
          }
          if (scenario != 'batch') await _until(tester, () => finished);
          if (scenario == 'encrypted') expect(candidates, 1);
        }
      }
      expect(
        Directory(folder.path)
            .listSync()
            .map((entry) => p.basename(entry.path)),
        [nfd],
      );
      await tester.pumpWidget(const SizedBox());
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
  await tester.pump();
  expect(ready(), isTrue);
}
