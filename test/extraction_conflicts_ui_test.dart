import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  for (final policy in [
    'skip',
    'rename',
    'merge',
    'overwrite',
    'cancel',
    'changed',
  ]) {
    testWidgets('主窗口解压重名策略 $policy', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-conflict-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, 'payload.txt'))
        ..writeAsStringSync('new');
      final archive = p.join(root.path, 'bundle.zip');
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest('compress', archive, inputs: [source.path]),
        ),
      );
      final target = Directory(p.join(root.path, 'bundle'))..createSync();
      final existing = File(p.join(target.path, 'payload.txt'))
        ..writeAsStringSync('old');
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
        if (call.method == 'chooseFolder') return [root.path];
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await _until(
        tester,
        () =>
            find.byKey(const ValueKey('row:payload.txt')).evaluate().isNotEmpty,
      );
      await tester.tap(find.text('解压到…'));
      await _until(tester, () => find.text('解压目标存在同名项目').evaluate().isNotEmpty);
      if (policy == 'cancel') {
        await tester.tap(find.text('取消解压'));
        await tester.pumpAndSettle();
        expect(existing.readAsStringSync(), 'old');
      } else {
        if (policy == 'changed') existing.writeAsStringSync('external change');
        await tester.tap(
          find.byKey(
            ValueKey(
              'extractionPolicy:${policy == 'changed' ? 'overwrite' : policy}',
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (policy == 'merge') {
          await _until(
            tester,
            () => find.text('解压目标存在同名项目').evaluate().isNotEmpty,
          );
          await tester.tap(find.byKey(const ValueKey('extractionPolicy:skip')));
        }
        if (policy == 'overwrite' || policy == 'changed') {
          expect(find.text('替换已有文件？'), findsOneWidget);
          expect(
            existing.readAsStringSync(),
            policy == 'changed' ? 'external change' : 'old',
          );
          await tester.tap(find.widgetWithText(FilledButton, '确定'));
        }
        await _until(
          tester,
          () =>
              find.textContaining('解压完成 ·').evaluate().isNotEmpty ||
              find.text('操作未完成').evaluate().isNotEmpty,
        );
        if (policy == 'changed') {
          expect(find.text('操作未完成'), findsOneWidget);
          expect(find.textContaining('已变化'), findsOneWidget);
          expect(existing.readAsStringSync(), 'external change');
          await tester.tap(find.text('知道了'));
        } else {
          expect(
            existing.readAsStringSync(),
            policy == 'overwrite' ? 'new' : 'old',
          );
          if (policy == 'rename') {
            expect(
              File(p.join(target.path, 'payload (2).txt')).readAsStringSync(),
              'new',
            );
          }
        }
      }
      expect(
        target.listSync().where(
          (entry) => p.basename(entry.path).startsWith('.f7zip-'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Finder 后台解压通过原生冲突选择重试，取消后保留文件', (tester) async {
    final root = Directory.systemTemp.createTempSync('f7zip-finder-conflict-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(p.join(root.path, 'payload.txt'))
      ..writeAsStringSync('old');
    final archive = p.join(root.path, 'bundle.zip');
    await tester.runAsync(
      () => ArchiveEngine().run(
        ArchiveRequest('compress', archive, inputs: [source.path]),
      ),
    );
    source.writeAsStringSync('external');
    final calls = <MethodCall>[];
    var conflicts = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'takeFinderRequests') {
        return [
          {
            'action': 'extractHere',
            'paths': [archive],
          },
          {
            'action': 'extractHere',
            'paths': [archive],
          },
        ];
      }
      if (call.method == 'finderExtractionConflict') {
        conflicts++;
        expect((call.arguments as Map)['paths'], ['payload.txt']);
        return conflicts == 1 ? 'rename' : null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    await _until(tester, () => conflicts == 2);
    await tester.pumpAndSettle();
    expect(source.readAsStringSync(), 'external');
    expect(
      File(p.join(root.path, 'payload (2).txt')).readAsStringSync(),
      'old',
    );
    expect(calls.where((call) => call.method == 'finderError'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
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
