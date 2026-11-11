import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/checksum_dialog.dart';
import 'package:f7zip/main.dart';
import 'package:f7zip/checksum_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('清单解析支持 GNU、SFV、BOM 和文件名转义，拒绝越界、重复与坏行', () {
    final digest = 'a' * 64;
    final entries = parseChecksumManifest(
      '\uFEFF# comment\r\n$digest *中文.txt\r\n'
      'CBF43926  file.txt\n995DC9BBDF1939FA *crc64.txt\n'
      ';sfv\nspace name.txt DEADBEEF\n\\$digest *line\\nbreak\\\\slash\\r\n',
    );
    expect(entries.map((entry) => entry.algorithm), [
      'sha256',
      'crc32',
      'crc64',
      'crc32',
      'sha256',
    ]);
    expect(entries.last.name, 'line\nbreak\\slash\r');
    for (final invalid in [
      '',
      'invalid line',
      '$digest *../outside',
      '$digest */etc/passwd',
      '$digest *dir/../file',
      '$digest *C:\\file',
      '$digest *\x00',
      '$digest *same\n$digest *./same',
      '\\$digest *invalid\\q',
      '\\$digest *invalid\\',
      List.filled(10001, '$digest *same').join('\n'),
    ]) {
      expect(() => parseChecksumManifest(invalid), throwsFormatException);
    }
  });

  test('读取清单限制大小并拒绝符号链接目标及链接父级', () async {
    final root = Directory.systemTemp.createTempSync('f7zip-manifest-');
    addTearDown(() => root.deleteSync(recursive: true));
    final actual = Directory(p.join(root.path, 'actual'))..createSync();
    final data = File(p.join(actual.path, 'file'))..writeAsStringSync('data');
    final link = Link(p.join(root.path, 'link'))..createSync(actual.path);
    final manifest = File(p.join(root.path, 'SHA256SUMS'));
    manifest.writeAsStringSync('${'a' * 64} *link/file\n');
    await expectLater(
      readChecksumManifest(manifest.path),
      throwsFormatException,
    );
    link.deleteSync();
    Link(p.join(root.path, 'alias')).createSync(data.path);
    manifest.writeAsStringSync('${'a' * 64} *alias\n');
    await expectLater(
      readChecksumManifest(manifest.path),
      throwsFormatException,
    );
    manifest.writeAsStringSync('x' * (4 * 1024 * 1024 + 1));
    await expectLater(
      readChecksumManifest(manifest.path),
      throwsFormatException,
    );
  });

  testWidgets('主窗口菜单进入校验工具后可以运行引擎并正常关闭', (tester) async {
    tester.view.physicalSize = const Size(860, 580);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-checksum-entry-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(p.join(root.path, '123.txt'))
      ..writeAsStringSync('123456789');
    const channel = MethodChannel('sevenzip/desktop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'chooseChecksumFiles') return [source.path];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const F7ZipApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('校验工具…'));
    await tester.tap(find.text('校验工具…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件计算'));
    await _until(tester, () => find.text('已计算 1 个文件').evaluate().isNotEmpty);
    expect(
      find.text(sha256.convert(source.readAsBytesSync()).toString()),
      findsOneWidget,
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(ChecksumDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('真实引擎计算、切换复制算法、保存并核验清单，已有清单保护可重试', (tester) async {
    tester.view.physicalSize = const Size(1120, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('f7zip-checksum-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(p.join(root.path, '123.txt'))
      ..writeAsStringSync('123456789');
    final target = File(p.join(root.path, 'SUMS'));
    var savePath = target.path;
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('sevenzip/desktop');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'chooseChecksumFiles') return [source.path];
      if (call.method == 'saveArchive') return savePath;
      if (call.method == 'openArchive') return [target.path];
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final engine = ArchiveEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: ChecksumDialog(
          run: (_, request) => engine.run(request),
          cancel: engine.cancel,
        ),
      ),
    );
    await tester.tap(find.text('选择文件计算'));
    await _until(tester, () => find.text('已计算 1 个文件').evaluate().isNotEmpty);
    expect(
      find.text(sha256.convert(source.readAsBytesSync()).toString()),
      findsOneWidget,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CRC64/XZ').last);
    await tester.pumpAndSettle();
    expect(find.text('995DC9BBDF1939FA'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, contains('995DC9BBDF1939FA'));
    target.writeAsStringSync('existing');
    await tester.tap(find.text('保存清单…'));
    await _until(
      tester,
      () => find.textContaining('无法保存结果').evaluate().isNotEmpty,
    );
    expect(target.readAsStringSync(), 'existing');
    savePath = p.join(root.path, 'newSUMS');
    await tester.tap(find.text('保存清单…'));
    await _until(
      tester,
      () => find.textContaining('清单已保存至').evaluate().isNotEmpty,
    );
    expect(
      File(savePath).readAsStringSync(),
      contains('995DC9BBDF1939FA *123.txt'),
    );
    target.writeAsStringSync(
      'CBF43926 *123.txt\n00000000 *missing\n00000000 *123.txt\n',
    );
    await tester.tap(find.text('核验清单…'));
    await _until(
      tester,
      () => find.textContaining('重复文件和算法').evaluate().isNotEmpty,
    );
    target.writeAsStringSync(
      'CBF43926 *123.txt\n00000000 *missing\n${'0' * 64} *123.txt\n',
    );
    await tester.tap(find.text('核验清单…'));
    await _until(
      tester,
      () => find.text('核验完成，1 / 3 项一致').evaluate().isNotEmpty,
    );
    expect(find.textContaining('文件缺失或不是实际普通文件'), findsOneWidget);
    expect(find.textContaining('摘要不一致'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(ready(), isTrue);
}
