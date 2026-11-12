import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实桌面宿主启动、打开 Unicode 归档并完成完整性测试', (tester) async {
    final root = await Directory.systemTemp.createTemp('f7zip-desktop-ui-');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await root.delete(recursive: true);
    });
    final source = File(p.join(root.path, '中文 😀.txt'));
    await source.writeAsString('desktop integration payload');
    final archive = p.join(root.path, '归档.zip');
    final engine = ArchiveEngine();
    await engine.run(
      ArchiveRequest('compress', archive, inputs: [source.path]),
    );

    await app.main([archive]);
    await _until(tester, find.byKey(const ValueKey('row:中文 😀.txt')));
    expect(find.textContaining('原生引擎加载失败'), findsNothing);
    await tester.tap(find.byIcon(Icons.verified_outlined));
    await _until(tester, find.text('测试通过，压缩包中的文件完整'));
    expect(tester.takeException(), isNull);

    final output = p.join(root.path, 'output');
    await engine.run(ArchiveRequest('extract', archive, destination: output));
    expect(
      await File(p.join(output, '中文 😀.txt')).readAsString(),
      'desktop integration payload',
    );
  });
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  final elapsed = Stopwatch()..start();
  while (finder.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 15)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
}
