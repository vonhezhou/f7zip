import 'dart:io';

import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');

  for (final (format, label) in [
    ('tar', 'TAR · 仅打包'),
    ('wim', 'WIM · 仅存储'),
    ('tar.gz', 'TAR.GZ'),
    ('tar.bz2', 'TAR.BZ2'),
    ('tar.xz', 'TAR.XZ'),
    ('gz', 'GZIP · 单文件'),
    ('xz', 'XZ · 单文件'),
    ('bz2', 'BZIP2 · 单文件'),
  ]) {
    testWidgets('通过新建弹窗创建 $format，隐藏密码并以只读方式浏览', (tester) async {
      tester.view.physicalSize = const Size(1120, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-formats-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, 'source.txt'))
        ..writeAsStringSync('new format through UI');
      final archive = File(p.join(root.path, 'created.$format'));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'chooseInputs') return [source.path];
        if (call.method == 'saveArchive') return archive.path;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建压缩包').last);
      await tester.pumpAndSettle();
      // 切换到不支持加密的格式后，之前输入的密码不得传入引擎。
      await tester.enterText(find.byType(TextField), 'secret');
      await tester.tap(find.byKey(const ValueKey('volumeSize')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义').last);
      await tester.pumpAndSettle();
      await _chooseFormat(tester, label);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('选择保存位置'));
      for (var attempt = 0; attempt < 150; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.text('只读浏览').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
      expect(archive.existsSync(), isTrue);
      expect(find.text('只读浏览'), findsOneWidget);
      final addButton = tester.widget<TextButton>(
        find.ancestor(
          of: find.byIcon(Icons.add_box_outlined),
          matching: find.byType(TextButton),
        ),
      );
      expect(addButton.onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final format in ['zip', 'zipx', '7z']) {
    testWidgets('$format 自定义分卷大小验证并自动打开首卷', (tester) async {
      tester.view.physicalSize = const Size(1120, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-create-volumes-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, 'payload.bin'))
        ..writeAsBytesSync(List<int>.generate(1200000, (_) => 0));
      final archive = p.join(root.path, 'split.$format');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'chooseInputs') return [source.path];
        if (call.method == 'saveArchive') return archive;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建压缩包').last);
      await tester.pumpAndSettle();
      if (format == '7z') await _chooseFormat(tester, '7z · 压缩率优先');
      if (format == 'zipx') await _chooseFormat(tester, 'ZIPX · LZMA 默认');
      await tester.tap(find.byKey(const ValueKey('volumeSize')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义').last);
      await tester.pumpAndSettle();
      final custom = find.byKey(const ValueKey('customVolumeSize'));
      for (final invalid in ['', '0', '-1', '1.5', 'abc', '2097152']) {
        await tester.enterText(custom, invalid);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '选择保存位置'))
              .onPressed,
          isNull,
        );
      }
      await tester.enterText(custom, '1');
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择保存位置'));
      for (var attempt = 0; attempt < 150; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.text('只读浏览').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
      expect(File('$archive.001').existsSync(), isTrue);
      expect(File(archive).existsSync(), isFalse);
      expect(find.text('只读浏览'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('单文件格式拒绝目录，切回 TAR 后恢复创建且压缩等级禁用', (tester) async {
    tester.view.physicalSize = const Size(860, 580);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-formats-input-');
    addTearDown(() => root.deleteSync(recursive: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'chooseInputs') return [root.path];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建压缩包').last);
    await tester.pumpAndSettle();
    await _chooseFormat(tester, 'GZIP · 单文件');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '选择保存位置'))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('此格式需要选择一个普通文件'), findsOneWidget);
    await _chooseFormat(tester, 'TAR · 仅打包');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '选择保存位置'))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byType(DropdownButtonFormField<int>),
          )
          .onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _chooseFormat(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('compressionFormat')));
  await tester.pumpAndSettle();
  final menu = find.byType(ListView).last;
  final scrollable = find.descendant(
    of: menu,
    matching: find.byType(Scrollable),
  );
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(
    find.descendant(of: menu, matching: find.text(label)),
    120,
    scrollable: scrollable,
  );
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}
