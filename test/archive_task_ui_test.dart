import 'dart:async';
import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/archive_task.dart';
import 'package:f7zip/archive_task_panel.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  for (final scenario in [
    'retry',
    'cancel',
    'password',
    'conflict',
    'dispose',
  ]) {
    testWidgets('批量队列逐项执行与恢复 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-queue-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = Directory(p.join(root.path, 'output'))..createSync();
      final archives = <String>[];
      await tester.runAsync(() async {
        for (var index = 1; index <= 3; index++) {
          final source = File(p.join(root.path, 'data$index.txt'))
            ..writeAsStringSync('payload $index');
          final archive = p.join(root.path, 'archive$index.zip');
          await ArchiveEngine().run(
            ArchiveRequest(
              'compress',
              archive,
              inputs: [source.path],
              password:
                  (scenario == 'cancel' && index < 3 || scenario == 'password')
                  ? 'secret'
                  : '',
            ),
          );
          archives.add(archive);
        }
      });
      if (scenario == 'retry') {
        File(archives[1]).writeAsStringSync('broken archive');
      }
      if (scenario == 'conflict') {
        final target = Directory(p.join(output.path, 'archive1'))..createSync();
        File(p.join(target.path, 'data1.txt')).writeAsStringSync('keep');
      }
      final password = Completer<String?>();
      final chooseFolder = Completer<String?>();
      var folderCalls = 0;
      var passwordCalls = 0;
      var finderErrors = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'takeFinderRequests':
            return [];
          case 'chooseArchives':
            return archives;
          case 'chooseFolder':
            return [output.path];
          case 'finderChooseFolder':
            folderCalls++;
            return scenario == 'dispose' ? chooseFolder.future : output.path;
          case 'finderPassword':
            passwordCalls++;
            return passwordCalls == 1 ? password.future : 'secret';
          case 'finderError':
            finderErrors++;
            return null;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await _until(
        tester,
        () =>
            find.byTooltip('打开  ⌘O').evaluate().isNotEmpty ||
            find.byTooltip('设置').evaluate().isNotEmpty,
      );
      // 等待初始化完成，批量入口只在桌面桥接就绪后启用。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump();
      if (scenario == 'cancel' || scenario == 'dispose') {
        await _native('finderRequest', {
          'action': 'extractTo',
          'paths': archives,
        });
      } else {
        unawaited(
          _native(
            'archiveCommand',
            scenario == 'password' ? 'batchTest' : 'batchExtract',
          ),
        );
      }
      await _until(tester, () => _tasks(tester).length == 3);
      if (scenario == 'dispose') {
        await _until(tester, () => folderCalls == 1);
        await tester.pumpWidget(const SizedBox());
        chooseFolder.complete(output.path);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pump();
        expect(output.listSync(), isEmpty);
      } else if (scenario == 'cancel') {
        await _until(tester, () => passwordCalls == 1);
        expect(_tasks(tester).map((task) => task.state), [
          ArchiveTaskState.running,
          ArchiveTaskState.queued,
          ArchiveTaskState.queued,
        ]);
        await _native('finderRequest', {
          'action': 'open',
          'paths': [archives[2]],
        });
        await tester.pump();
        expect(_tasks(tester).length, 4);
        expect(_tasks(tester).last.state, ArchiveTaskState.queued);
        await tester.tap(find.byKey(const ValueKey('cancel-task:2')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('cancel-task:1')));
        await tester.pump();
        password.complete('secret');
        await _until(
          tester,
          () => _tasks(tester).every((task) => task.finished),
        );
        expect(_tasks(tester).map((task) => task.state), [
          ArchiveTaskState.cancelled,
          ArchiveTaskState.cancelled,
          ArchiveTaskState.succeeded,
          ArchiveTaskState.succeeded,
        ]);
        expect(File(p.join(output.path, 'data1.txt')).existsSync(), isFalse);
        expect(File(p.join(output.path, 'data2.txt')).existsSync(), isFalse);
        expect(
          File(p.join(output.path, 'data3.txt')).readAsStringSync(),
          'payload 3',
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('retry-task:1')),
          56,
          scrollable: find.descendant(
            of: find.byType(ArchiveTaskPanel),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('retry-task:1')));
        await _until(
          tester,
          () => _tasks(tester).every((task) => task.finished),
        );
        expect(_tasks(tester).last.state, ArchiveTaskState.succeeded);
        expect(
          File(p.join(output.path, 'data1.txt')).readAsStringSync(),
          'payload 1',
        );
        expect(folderCalls, 1);
        expect(finderErrors, 0);
      } else if (scenario == 'password') {
        for (var index = 0; index < 3; index++) {
          for (final value in ['bad', 'secret']) {
            await _until(
              tester,
              () => find.text('压缩包密码').evaluate().isNotEmpty,
            );
            await tester.enterText(find.byType(TextField).last, value);
            await tester.tap(find.text('确定'));
            await tester.pumpAndSettle();
          }
        }
        await _until(
          tester,
          () => _tasks(tester).every((task) => task.finished),
        );
        expect(
          _tasks(tester).every(
            (task) =>
                task.state == ArchiveTaskState.succeeded && task.error == null,
          ),
          isTrue,
        );
        expect(output.listSync(), isEmpty);
      } else {
        if (scenario == 'conflict') {
          await _until(tester, () => find.text('取消解压').evaluate().isNotEmpty);
          await tester.tap(find.text('取消解压'));
        }
        await _until(
          tester,
          () => _tasks(tester).every((task) => task.finished),
        );
        final retry = _tasks(tester)
            .singleWhere((task) => task.state != ArchiveTaskState.succeeded);
        expect(
          retry.state,
          scenario == 'retry'
              ? ArchiveTaskState.failed
              : ArchiveTaskState.cancelled,
        );
        expect(
          File(p.join(output.path, 'archive3', 'data3.txt')).readAsStringSync(),
          'payload 3',
        );
        if (scenario == 'retry') {
          File(archives[0]).copySync(archives[1]);
        } else {
          expect(
            File(p.join(output.path, 'archive1', 'data1.txt'))
                .readAsStringSync(),
            'keep',
          );
        }
        await tester.ensureVisible(
          find.byKey(ValueKey('retry-task:${retry.id}')),
        );
        await tester.tap(find.byKey(ValueKey('retry-task:${retry.id}')));
        if (scenario == 'conflict') {
          await _until(
            tester,
            () => find
                .byKey(const ValueKey('extractionPolicy:rename'))
                .evaluate()
                .isNotEmpty,
          );
          await tester.tap(
            find.byKey(const ValueKey('extractionPolicy:rename')),
          );
        }
        await _until(
          tester,
          () => _tasks(tester).every((task) => task.finished),
        );
        expect(
          _tasks(tester)
              .every((task) => task.state == ArchiveTaskState.succeeded),
          isTrue,
        );
        if (scenario == 'retry') {
          expect(
            File(p.join(output.path, 'archive2', 'data1.txt'))
                .readAsStringSync(),
            'payload 1',
          );
        }
        if (scenario == 'conflict') {
          expect(
            File(p.join(output.path, 'archive1', 'data1.txt'))
                .readAsStringSync(),
            'keep',
          );
          expect(
            File(p.join(output.path, 'archive1', 'data1 (2).txt'))
                .readAsStringSync(),
            'payload 1',
          );
        }
        await tester.tap(find.byTooltip('清除已结束任务'));
        await tester.pump();
        expect(_tasks(tester), isEmpty);
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
  for (var attempt = 0; attempt < 200 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pump();
  expect(ready(), isTrue);
}
