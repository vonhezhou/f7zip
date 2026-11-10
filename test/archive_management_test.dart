import 'dart:async';
import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('通过原生菜单管理包内目录、添加冲突和删除确认', (tester) async {
    tester.view.physicalSize = const Size(1120, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-management-');
    addTearDown(() => root.deleteSync(recursive: true));
    final original = File(p.join(root.path, 'original.txt'))
      ..writeAsStringSync('keep');
    final added = File(p.join(root.path, 'added.txt'))
      ..writeAsStringSync('first');
    final archive = p.join(root.path, 'manage.zip');
    final engine = ArchiveEngine();
    await tester.runAsync(
      () => engine.run(
        ArchiveRequest('compress', archive, inputs: [original.path]),
      ),
    );
    const channel = MethodChannel('sevenzip/desktop');
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
        case 'chooseInputs':
          return [added.path];
        case 'workspaceDirectory':
          return p.join(root.path, 'sessions');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Future<void> command(String value) async {
      // 模拟 macOS 菜单进入 Flutter 的真实消息边界。
      unawaited(
        messenger.handlePlatformMessage(
          'sevenzip/desktop',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('archiveCommand', value),
          ),
          (_) {},
        ),
      );
      await tester.pump();
    }

    Future<void> select(String path) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('row:$path')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pump();
    }

    await tester.pumpWidget(const F7ZipApp());
    await until(
      tester,
      () =>
          find.byKey(const ValueKey('row:original.txt')).evaluate().isNotEmpty,
    );
    await command('mkdir');
    await tester.enterText(find.byType(TextField).last, 'docs');
    await tester.tap(find.text('确定'));
    await until(
      tester,
      () => find.byKey(const ValueKey('row:docs')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('row:docs')));
    await tester.pumpAndSettle();
    await command('add');
    await until(
      tester,
      () => find
          .byKey(const ValueKey('row:docs/added.txt'))
          .evaluate()
          .isNotEmpty,
    );
    added.writeAsStringSync('replacement');
    await command('add');
    await until(tester, () => find.text('替换同名文件').evaluate().isNotEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await command('add');
    await until(tester, () => find.text('替换同名文件').evaluate().isNotEmpty);
    await tester.tap(find.text('确定'));
    await until(tester, () => find.text('添加并替换文件完成').evaluate().isNotEmpty);
    await select('docs/added.txt');
    await command('rename');
    await tester.enterText(find.byType(TextField).last, 'renamed.txt');
    await tester.tap(find.text('确定'));
    await until(
      tester,
      () => find
          .byKey(const ValueKey('row:docs/renamed.txt'))
          .evaluate()
          .isNotEmpty,
    );
    await command('properties');
    expect(find.text('CRC32'), findsOneWidget);
    expect(find.text('压缩方法'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await command('remove');
    expect(find.text('从压缩包删除'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('row:docs/renamed.txt')), findsOneWidget);
    final output = p.join(root.path, 'output');
    await tester.runAsync(
      () => engine.run(ArchiveRequest('extract', archive, destination: output)),
    );
    expect(
      File(p.join(output, 'docs/renamed.txt')).readAsStringSync(),
      'replacement',
    );
    expect(File(p.join(output, 'original.txt')).readAsStringSync(), 'keep');
    await command('remove');
    await tester.tap(find.text('确定'));
    await until(tester, () => find.text('删除条目完成').evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('row:docs/renamed.txt')), findsNothing);
    await command('back');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('row:original.txt')), findsOneWidget);
    await command('forward');
    await tester.pumpAndSettle();
    expect(find.text('manage.zip / docs'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) return;
  }
  fail('压缩包管理操作未完成');
}
