import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final width in [900.0, 1120.0]) {
    testWidgets('更多操作在 $width 宽窗口内分层展示并可关闭', (tester) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('f7zip-menu-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, 'hello.txt'))
        ..writeAsStringSync('menu');
      final archive = p.join(root.path, 'sample.zip');
      await tester.runAsync(
        () => ArchiveEngine().run(
          ArchiveRequest('compress', archive, inputs: [source.path]),
        ),
      );
      const channel = MethodChannel('sevenzip/desktop');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
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
      final row = find.byKey(const ValueKey('row:hello.txt'));
      for (var i = 0; i < 200 && row.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.byType(SubmenuButton), findsNWidgets(4));
      expect(find.byType(MenuItemButton), findsNWidgets(4));
      expect(find.text('修复 ZIP…'), findsNothing);
      final top = tester.getRect(find.widgetWithText(MenuItemButton, '属性'));
      final bottom = tester.getRect(
        find.widgetWithText(MenuItemButton, '关于 F7Zip'),
      );
      expect(bottom.bottom - top.top, lessThan(340));

      for (final group in ['查看与导航', '解压', '编辑压缩包', '工具']) {
        await tester.tap(find.widgetWithText(SubmenuButton, group));
        await tester.pumpAndSettle();
        for (final element in find.byType(MenuItemButton).evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(600));
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(SubmenuButton), findsNothing);
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SubmenuButton), findsNothing);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SubmenuButton, '查看与导航'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('隐藏文件树'));
      await tester.pumpAndSettle();
      expect(find.byType(SubmenuButton), findsNothing);
      expect(find.byTooltip('显示侧栏'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
