import 'dart:async';
import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/archive_task.dart';
import 'package:f7zip/archive_task_panel.dart';
import 'package:f7zip/main.dart';
import 'package:f7zip/edit_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  for (final scenario in [
    'open',
    'extract',
    'test',
    'split',
    'preview',
    'finder',
    'batch',
    'nested',
    'edit',
    'restored',
    'manual',
    'locked',
    'disabled',
    'cancel',
    'dispose',
    'queueCancel',
  ]) {
    testWidgets('常用密码授权与真实加密归档流程 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-password-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = Directory(p.join(root.path, 'source'))..createSync();
      final data = File(p.join(source.path, 'data.txt'))
        ..writeAsStringSync('payload');
      final archive = p.join(
        root.path,
        scenario == 'open' ? 'encrypted.7z' : 'encrypted.zip',
      );
      final output = Directory(p.join(root.path, 'output'))..createSync();
      final workspace = Directory(p.join(root.path, 'workspace'))..createSync();
      await tester.runAsync(() async {
        var input = data.path;
        if (scenario == 'nested') {
          input = p.join(source.path, 'inner.7z');
          await ArchiveEngine().run(
            ArchiveRequest(
              'compress',
              input,
              format: '7z',
              inputs: [data.path],
              password: 'secret',
            ),
          );
        }
        await ArchiveEngine().run(
          ArchiveRequest(
            'compress',
            archive,
            format: scenario == 'open' ? '7z' : 'zip',
            inputs: [input],
            password: 'secret',
          ),
        );
      });
      if (scenario == 'restored') {
        await tester.runAsync(() async {
          final listing = await ArchiveEngine().run(
            ArchiveRequest('list', archive),
          );
          final edits = EditWorkspace(
            root: workspace,
            canUpdate: () => false,
            update: (_, _) async => 'unused',
            onChanged: () {},
          );
          await edits.root.create(recursive: true);
          final directory = await edits.root.createTemp('edit-');
          final file = await data.copy(p.join(directory.path, 'data.txt'));
          await edits.track(
            directory: directory,
            archive: archive,
            itemPath: 'data.txt',
            file: file,
            version: listing['version'] as String,
            requiresPassword: true,
            password: 'secret',
          );
          edits.close();
          await file.writeAsString('updated');
        });
      }
      var candidateCalls = 0;
      var nativePasswords = 0;
      final candidates = Completer<List<String>>();
      String? viewed;
      Map? shown;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'loadSettings':
            return {'autoTryPasswords': scenario != 'disabled'};
          case 'takeFinderRequests':
            return [
              {
                'action': scenario == 'finder' ? 'extractHere' : 'open',
                'paths': [archive],
              },
            ];
          case 'workspaceDirectory':
            return workspace.path;
          case 'chooseFolder':
            return [output.path];
          case 'openArchive':
            return [archive];
          case 'saveArchive':
            return p.join(root.path, 'archive-parts');
          case 'chooseArchives':
            return [archive];
          case 'archivePasswordCandidates':
            candidateCalls++;
            if (['dispose', 'queueCancel'].contains(scenario)) {
              return candidates.future;
            }
            if (scenario == 'locked') {
              throw PlatformException(code: 'keychain', message: 'locked');
            }
            return ['manual', 'cancel', 'finder'].contains(scenario)
                ? ['wrong']
                : ['bad', 'bad', 'secret'];
          case 'finderPassword':
            nativePasswords++;
            return 'secret';
          case 'createArchivePreviewDirectory':
          case 'createNestedArchiveDirectory':
            final directory = Directory(
              p.join(
                root.path,
                'temporary-${DateTime.now().microsecondsSinceEpoch}',
              ),
            )..createSync();
            return directory.path;
          case 'discardArchivePreviewDirectory':
          case 'discardNestedArchiveDirectory':
            final directory = Directory(call.arguments as String);
            if (directory.existsSync()) directory.deleteSync(recursive: true);
            return null;
          case 'showArchivePreview':
            shown = call.arguments as Map;
            return null;
          case 'launchFile':
            viewed = (call.arguments as Map)['path'] as String;
            return null;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      if (scenario == 'finder') {
        await _until(
          tester,
          () =>
              File(p.join(root.path, 'data.txt')).existsSync() &&
              _tasks(tester).every((task) => task.finished),
        );
        expect(nativePasswords, 1);
        expect(candidateCalls, 1);
      } else {
        final row = scenario == 'nested' ? 'inner.7z' : 'data.txt';
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
        if (scenario == 'restored') {
          await _until(
            tester,
            () => find.textContaining('已自动更新压缩包').evaluate().isNotEmpty,
          );
        }
        var finished = false;
        final command = switch (scenario) {
          'extract' => 'extract',
          'preview' => 'preview',
          'nested' => 'nested',
          'edit' => 'edit',
          'batch' => 'batchTest',
          _ => 'test',
        };
        if (scenario == 'split') {
          unawaited(
            _native('archiveCommand', 'test').then((_) => finished = true),
          );
          await _until(tester, () => finished);
          expect(candidateCalls, 1);
          unawaited(_native('archiveCommand', 'splitFile'));
          await _until(
            tester,
            () => find
                .byKey(const ValueKey('filePartSize'))
                .evaluate()
                .isNotEmpty,
          );
          await tester.tap(find.text('选择输出名称'));
          await _until(
            tester,
            () => find.text('文件分割完成 · 1 片，已保存校验清单').evaluate().isNotEmpty,
          );
          finished = false;
        }
        if (scenario == 'queueCancel') {
          await _native('finderRequest', {
            'action': 'test',
            'fromFinder': false,
            'paths': [archive, archive],
          });
        } else {
          unawaited(
            _native('archiveCommand', command).then((_) => finished = true),
          );
        }
        if (scenario == 'dispose') {
          await _until(tester, () => candidateCalls == 1);
          await tester.pumpWidget(const SizedBox());
          candidates.complete(['secret']);
          await _until(tester, () => finished);
        } else if (scenario == 'queueCancel') {
          await _until(tester, () => candidateCalls == 1);
          await tester.tap(find.byKey(const ValueKey('cancel-task:2')));
          await tester.pump();
          candidates.complete(['secret']);
          await _until(
            tester,
            () => _tasks(tester).every((task) => task.finished),
          );
          expect(_tasks(tester).map((task) => task.state), [
            ArchiveTaskState.succeeded,
            ArchiveTaskState.cancelled,
            ArchiveTaskState.succeeded,
          ]);
        } else {
          if (['manual', 'locked', 'disabled', 'cancel'].contains(scenario)) {
            await _until(
              tester,
              () => find.text('压缩包密码').evaluate().isNotEmpty,
            );
            if (scenario == 'locked') {
              expect(find.textContaining('钥匙串暂时不可用'), findsOneWidget);
            }
            if (scenario == 'cancel') {
              await tester.tap(find.text('取消'));
            } else {
              await tester.enterText(find.byType(TextField).last, 'secret');
              await tester.tap(find.text('确定'));
            }
            await tester.pumpAndSettle();
          }
          await _until(tester, () => finished);
          expect(find.text('压缩包密码'), findsNothing);
          expect(find.text('操作未完成'), findsNothing);
          expect(
            candidateCalls,
            scenario == 'disabled'
                ? 0
                : scenario == 'nested'
                ? 2
                : 1,
          );
          if (scenario == 'preview') {
            expect(
              File(shown!['path'] as String).readAsStringSync(),
              'payload',
            );
          }
          if (scenario == 'extract') {
            expect(
              File(p.join(output.path, 'encrypted', 'data.txt'))
                  .readAsStringSync(),
              'payload',
            );
          }
          if (scenario == 'nested') {
            expect(find.text('子包 · 只读浏览'), findsOneWidget);
            finished = false;
            unawaited(
              _native(
                'archiveCommand',
                'parentArchive',
              ).then((_) => finished = true),
            );
            await _until(tester, () => finished);
          }
          if (scenario == 'edit' || scenario == 'restored') {
            if (scenario == 'edit') {
              expect(viewed, isNotNull);
              File(viewed!).writeAsStringSync('updated');
            }
            if (scenario == 'edit') {
              await _until(
                tester,
                () => find.textContaining('已自动更新压缩包').evaluate().isNotEmpty,
              );
            }
            final result = await tester.runAsync(
              () => ArchiveEngine().run(
                ArchiveRequest(
                  'extract',
                  archive,
                  password: 'secret',
                  destination: p.join(root.path, 'verified'),
                ),
              ),
            );
            expect(result!['ok'], isTrue);
            expect(
              File(p.join(root.path, 'verified', 'data.txt'))
                  .readAsStringSync(),
              'updated',
            );
            for (final file
                in workspace
                    .listSync(recursive: true)
                    .whereType<File>()
                    .where((file) => file.path.endsWith('.json'))) {
              expect(file.readAsStringSync(), isNot(contains('secret')));
            }
          }
          if (!['cancel', 'batch'].contains(scenario)) {
            final before = candidateCalls;
            finished = false;
            unawaited(
              _native('archiveCommand', 'test').then((_) => finished = true),
            );
            await _until(tester, () => finished);
            expect(candidateCalls, before);
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}

List<ArchiveTask> _tasks(WidgetTester tester) {
  final panel = find.byType(ArchiveTaskPanel);
  return panel.evaluate().isEmpty
      ? []
      : tester.widget<ArchiveTaskPanel>(panel).tasks;
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
  for (var attempt = 0; attempt < 250 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump();
  expect(ready(), isTrue);
}
