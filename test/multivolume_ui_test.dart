import 'dart:io';
import 'dart:math';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('分卷直接浏览与解压，缺卷显示操作错误并保留当前列表', (tester) async {
    tester.view.physicalSize = const Size(860, 580);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-volume-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final random = Random(42);
    final payload = List<int>.generate(50000, (_) => random.nextInt(256));
    final source = File(p.join(root.path, 'payload.bin'))
      ..writeAsBytesSync(payload);
    final archive = File(p.join(root.path, 'bundle.7z'));
    await tester.runAsync(
      () => ArchiveEngine().run(
        ArchiveRequest(
          'compress',
          archive.path,
          format: '7z',
          inputs: [source.path],
        ),
      ),
    );
    final data = archive.readAsBytesSync();
    final parts = <File>[];
    for (var offset = 0; offset < data.length; offset += 10000) {
      final index = (parts.length + 1).toString().padLeft(3, '0');
      parts.add(
        File('${archive.path}.$index')..writeAsBytesSync(
          data.sublist(offset, min(offset + 10000, data.length)),
        ),
      );
    }
    const channel = MethodChannel('sevenzip/desktop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'takeFinderRequests':
          return [
            {
              'action': 'open',
              'paths': [parts.first.path],
            },
          ];
        case 'openArchive':
          return [parts.first.path];
        case 'chooseFolder':
          return [root.path];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    final row = find.byKey(const ValueKey('row:payload.bin'));
    await _until(tester, () => row.evaluate().isNotEmpty);
    expect(find.text('只读浏览'), findsOneWidget);
    expect(find.textContaining(' · ${parts.length} 卷'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.ancestor(
              of: find.byIcon(Icons.add_box_outlined),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('解压到…'));
    await _until(
      tester,
      () => find.textContaining('解压完成 ·').evaluate().isNotEmpty,
    );
    expect(
      File(p.join(root.path, 'bundle', 'payload.bin')).readAsBytesSync(),
      payload,
    );
    parts[1].deleteSync();
    await tester.tap(find.text('打开'));
    await _until(tester, () => find.text('操作未完成').evaluate().isNotEmpty);
    expect(find.text('压缩包密码'), findsNothing);
    expect(find.textContaining('分卷'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    if (ready()) return;
  }
  fail('分卷操作未完成');
}
