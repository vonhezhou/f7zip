import 'dart:async';
import 'dart:io';

import 'package:f7zip/archive_backup.dart';
import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/edit_workspace.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final scenario in [
    'updateNewer',
    'updateExisting',
    'syncDirectory',
    'cancel',
    'editing',
  ]) {
    testWidgets('更新模式真实引擎流程 $scenario', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-update-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = Directory(p.join(root.path, 'docs'))..createSync();
      final old = File(p.join(source.path, 'old.txt'))
        ..writeAsStringSync('old data');
      old.setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final removed = File(p.join(source.path, 'removed.txt'))
        ..writeAsStringSync('keep unless sync');
      final archive = p.join(root.path, 'sample.zip');
      final listing = await tester.runAsync(() async {
        final engine = ArchiveEngine();
        await engine.run(
          ArchiveRequest('compress', archive, inputs: [source.path]),
        );
        return engine.run(ArchiveRequest('list', archive));
      });
      final original = File(archive).readAsBytesSync();
      final workspace = Directory(p.join(root.path, 'workspace'))..createSync();
      if (scenario == 'editing') {
        await tester.runAsync(() async {
          final edits = EditWorkspace(
            root: workspace,
            canUpdate: () => false,
            update: (_, _) async => 'unused',
            onChanged: () {},
          );
          final directory = await workspace.createTemp('edit-');
          final file = await old.copy(p.join(directory.path, 'old.txt'));
          await edits.track(
            directory: directory,
            archive: archive,
            itemPath: 'docs/old.txt',
            file: file,
            version: listing!['version'] as String,
            requiresPassword: false,
            password: '',
          );
          edits.close();
        });
      }
      old.writeAsStringSync('updated data');
      old.setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(1700000100000),
      );
      removed.deleteSync();
      File(p.join(source.path, 'added.txt')).writeAsStringSync('new data');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('sevenzip/desktop');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'workspaceDirectory') return workspace.path;
        if (call.method == 'chooseInputs') return [source.path];
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
        () => find.byKey(const ValueKey('row:docs')).evaluate().isNotEmpty,
      );
      if (scenario == 'editing') {
        await _until(tester, () => find.text('管理编辑文件').evaluate().isNotEmpty);
      }
      var finished = false;
      unawaited(_command('updateMode').then((_) => finished = true));
      if (scenario == 'editing') {
        await _until(tester, () => find.text('知道了').evaluate().isNotEmpty);
        expect(find.textContaining('此压缩包正在外部编辑'), findsOneWidget);
        await tester.tap(find.text('知道了'));
      } else {
        await _until(tester, () => find.text('更新模式').evaluate().isNotEmpty);
        final label = switch (scenario) {
          'updateNewer' => '按时间更新',
          'updateExisting' => '仅更新已有条目',
          _ => '同步目录',
        };
        await tester.tap(find.text(label));
        if (label == '同步目录') {
          await _until(tester, () => find.text('确认同步目录').evaluate().isNotEmpty);
          await tester.tap(find.text(scenario == 'cancel' ? '取消' : '确定'));
        }
      }
      await _until(tester, () => finished);
      if (scenario == 'cancel' || scenario == 'editing') {
        expect(File(archive).readAsBytesSync(), original);
        expect(
          await tester.runAsync(() => findArchiveBackups(archive)),
          isEmpty,
        );
      } else {
        final backups = await tester.runAsync(
          () => findArchiveBackups(archive),
        );
        expect(backups, hasLength(1));
        expect(File(backups!.single.path).readAsBytesSync(), original);
        final output = p.join(root.path, 'output');
        await tester.runAsync(
          () => ArchiveEngine().run(
            ArchiveRequest('extract', archive, destination: output),
          ),
        );
        expect(
          File(p.join(output, 'docs/old.txt')).readAsStringSync(),
          'updated data',
        );
        expect(
          File(p.join(output, 'docs/added.txt')).existsSync(),
          scenario != 'updateExisting',
        );
        expect(
          File(p.join(output, 'docs/removed.txt')).existsSync(),
          scenario != 'syncDirectory',
        );
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
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.pumpAndSettle();
  expect(ready(), isTrue);
}
