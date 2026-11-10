import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('含链接 ZIP 只读打开，通过主窗口安全解压', (tester) async {
    tester.view.physicalSize = const Size(1120, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-links-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = Directory(p.join(root.path, 'source'))..createSync();
    File(p.join(source.path, 'data')).writeAsStringSync('payload');
    Link(p.join(source.path, 'alias')).createSync('data');
    final archive = p.join(root.path, 'bundle.zip');
    await tester.runAsync(
      () => ArchiveEngine().run(
        ArchiveRequest('compress', archive, inputs: [source.path]),
      ),
    );
    const channel = MethodChannel('sevenzip/desktop');
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
    await _until(tester, () => find.text('只读浏览').evaluate().isNotEmpty);
    final addButton = tester.widget<TextButton>(
      find.ancestor(of: find.text('添加'), matching: find.byType(TextButton)),
    );
    expect(addButton.onPressed, isNull);
    await tester.tap(find.text('解压到…'));
    await _until(
      tester,
      () => find.textContaining('解压完成 ·').evaluate().isNotEmpty,
    );
    final alias = Link(p.join(root.path, 'bundle', 'source', 'alias'));
    expect(alias.existsSync(), isTrue);
    expect(alias.targetSync(), 'data');
    expect(File(alias.path).readAsStringSync(), 'payload');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 150 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(ready(), isTrue);
}
