import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final scenario in [
    'dictionary',
    'characters',
    'pause',
    'budget',
    'sourceChange',
  ]) {
    testWidgets('自有归档密码恢复真实入口 $scenario', (tester) async {
      tester.view.physicalSize = scenario == 'dictionary'
          ? const Size(860, 580)
          : const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-recovery-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, 'data.txt'))
        ..writeAsStringSync('private payload');
      final archive = File(p.join(root.path, 'encrypted.7z'));
      final password = scenario == 'characters' ? 'known-10!' : 'secret';
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest(
            'compress',
            archive.path,
            format: '7z',
            inputs: [source.path],
            password: password,
          ),
        ),
      );
      final before = archive.readAsBytesSync();
      const desktop = MethodChannel('sevenzip/desktop');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(desktop, (call) async {
        if (call.method == 'openArchive') return [archive.path];
        return null;
      });
      String? clipboard;
      const platformChannel = MethodChannel(
        'flutter/platform',
        JSONMethodCodec(),
      );
      messenger.setMockMethodCallHandler(platformChannel, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(desktop, null);
        messenger.setMockMethodCallHandler(platformChannel, null);
      });
      await tester.pumpWidget(const F7ZipApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('自有归档密码恢复…'));
      await tester.tap(find.text('自有归档密码恢复…'));
      await tester.pumpAndSettle();
      expect(find.text('自有归档密码恢复'), findsOneWidget);
      if (scenario == 'characters') {
        await tester.tap(find.text('字符范围'));
        await tester.pumpAndSettle();
        for (final entry in {
          '字符表（最多 64 个不同字符）': '01',
          '最短长度': '2',
          '最长长度（最多 8）': '2',
          '已知前缀': 'known-',
          '已知后缀': '!',
        }.entries) {
          await tester.enterText(
            find.widgetWithText(TextField, entry.key),
            entry.value,
          );
        }
      } else {
        final words = find.widgetWithText(
          TextField,
          '每行一个候选，最多 10000 个 / 4 MiB',
        );
        await tester.tap(find.text('开始搜索'));
        await tester.pumpAndSettle();
        expect(find.text('请输入 1–10000 个候选，每行一个'), findsOneWidget);
        final longSearch = [
          'pause',
          'budget',
          'sourceChange',
        ].contains(scenario);
        final candidates = longSearch
            ? [
                ...List.generate(
                  scenario == 'budget' ? 10000 : 256,
                  (i) => 'wrong-$i',
                ),
              ]
            : ['wrong', 'secret', 'unused'];
        if (scenario != 'budget') candidates.add('secret');
        await tester.enterText(words, candidates.join('\n'));
      }
      if (scenario == 'budget') {
        await tester.enterText(
          find.widgetWithText(TextField, '本轮运行上限（秒，1–3600）'),
          '1',
        );
      }
      await tester.tap(find.text('开始搜索'));
      if (['pause', 'sourceChange'].contains(scenario)) {
        await _until(tester, () => find.text('暂停').evaluate().isNotEmpty);
        await tester.tap(find.text('暂停'));
        await _until(tester, () => find.text('继续搜索').evaluate().isNotEmpty);
        expect(find.textContaining('已暂停'), findsOneWidget);
        if (scenario == 'sourceChange') {
          archive.setLastModifiedSync(DateTime(2001));
        }
        await tester.tap(find.text('继续搜索'));
      }
      if (scenario == 'budget') {
        await _until(
          tester,
          () => find.text('本轮已达运行上限，已暂停').evaluate().isNotEmpty,
        );
        expect(find.text('继续搜索'), findsOneWidget);
      } else if (scenario == 'sourceChange') {
        await _until(
          tester,
          () => find.textContaining('归档已变化').evaluate().isNotEmpty,
        );
        expect(find.byTooltip('复制恢复的密码'), findsNothing);
      } else {
        await _until(
          tester,
          () => find.byTooltip('复制恢复的密码').evaluate().isNotEmpty,
        );
        expect(find.text('已找到密码并验证一个加密文件条目'), findsOneWidget);
        expect(find.text(password), findsNothing);
        await tester.ensureVisible(find.byTooltip('显示密码'));
        await tester.tap(find.byTooltip('显示密码'));
        await tester.pump();
        expect(find.text(password), findsOneWidget);
        await tester.tap(find.byTooltip('复制恢复的密码'));
        await tester.pumpAndSettle();
        expect(clipboard, password);
        if (scenario == 'dictionary') {
          await tester.tap(find.text('重新配置'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('开始搜索'));
          await _until(
            tester,
            () => find.byTooltip('复制恢复的密码').evaluate().isNotEmpty,
          );
          expect(find.text(password), findsNothing);
          expect(find.byTooltip('显示密码'), findsOneWidget);
        }
      }
      expect(archive.readAsBytesSync(), before);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('自有归档密码恢复'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var index = 0; index < 300 && !ready(); index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(ready(), isTrue);
}
