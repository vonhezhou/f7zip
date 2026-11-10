import 'dart:convert';
import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('设置切换编码刷新文件树，外部编辑保留原编码并阻止切换覆盖会话', (tester) async {
    tester.view.physicalSize = const Size(1120, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-encoding-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final archive = p.join(root.path, 'legacy.zip');
    await tester.runAsync(() async {
      final created = await Process.run('/usr/bin/python3', [
        '-c',
        '''import sys, zipfile
class LegacyInfo(zipfile.ZipInfo):
    def _encodeFilenameFlags(self):
        return self.filename.encode('cp932'), self.flag_bits & ~0x800
with zipfile.ZipFile(sys.argv[1], 'w') as output:
    output.writestr(LegacyInfo('資料ファイルこんにちは.txt'), b'original')
    output.writestr(LegacyInfo('報告書日本語.txt'), b'keep')
''',
        archive,
      ]);
      expect(created.exitCode, 0, reason: '${created.stderr}');
    });
    const channel = MethodChannel('sevenzip/desktop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map<String, dynamic> settings = {'filenameEncoding': 'dos'};
    String? workingFile;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'loadSettings':
          return settings;
        case 'saveSettings':
          settings = Map<String, dynamic>.from(call.arguments as Map);
          return null;
        case 'takeFinderRequests':
          return [
            {
              'action': 'open',
              'paths': [archive],
            },
          ];
        case 'workspaceDirectory':
          return p.join(root.path, 'sessions');
        case 'launchFile':
          workingFile = (call.arguments as Map)['path'] as String;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    await _until(tester, () => find.text('legacy.zip').evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('row:資料ファイルこんにちは.txt')), findsNothing);
    await _chooseEncoding(tester, '日文 Shift-JIS');
    final row = find.byKey(const ValueKey('row:資料ファイルこんにちは.txt'));
    await _until(tester, () => row.evaluate().isNotEmpty);
    expect(settings['filenameEncoding'], 'shiftJis');
    await tester.tap(find.descendant(of: row, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await _until(tester, () => workingFile != null);
    final manifests = Directory(p.join(root.path, 'sessions'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => p.basename(file.path) == 'session.json');
    expect(manifests.length, 1);
    expect(jsonDecode(manifests.single.readAsStringSync())['codePage'], 932);
    await _chooseEncoding(tester, 'DOS CP437');
    await _until(tester, () => find.text('知道了').evaluate().isNotEmpty);
    expect(find.textContaining('请结束监控后再切换文件名编码'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    await tester.runAsync(
      () => File(workingFile!).writeAsString('saved in editor', flush: true),
    );
    await _until(
      tester,
      () => find.textContaining('已自动更新压缩包').evaluate().isNotEmpty,
    );
    final output = p.join(root.path, 'verified');
    await tester.runAsync(
      () => ArchiveEngine().run(
        ArchiveRequest('extract', archive, destination: output, codePage: 932),
      ),
    );
    expect(
      File(p.join(output, '資料ファイルこんにちは.txt')).readAsStringSync(),
      'saved in editor',
    );
    expect(File(p.join(output, '報告書日本語.txt')).readAsStringSync(), 'keep');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _chooseEncoding(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('设置'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('filenameEncoding')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label).last);
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('保存设置'));
  await tester.pumpAndSettle();
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    if (ready()) return;
  }
  fail('文件名编码操作未完成');
}
