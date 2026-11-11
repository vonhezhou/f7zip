import 'package:f7zip/window_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('窗口控件调用原生操作并同步全屏状态', (tester) async {
    const channel = MethodChannel('sevenzip/window');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'state') return {'focused': true, 'fullScreen': false};
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WindowControls())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('最小化窗口'));
    await tester.tap(find.byTooltip('进入全屏'));
    await tester.tap(find.byTooltip('关闭窗口'));
    expect(calls, ['state', 'minimize', 'fullScreen', 'close']);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('stateChanged', {
          'focused': false,
          'fullScreen': true,
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    expect(find.byTooltip('进入全屏'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('标题留白支持拖动与双击，子按钮点击独立处理', (tester) async {
    const channel = MethodChannel('sevenzip/window');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const WindowDragArea(child: SizedBox(width: 300, height: 52)),
              TextButton(
                onPressed: () => calls.add('tool'),
                child: const Text('工具'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('工具'));
    expect(calls, ['tool']);
    final area = find.byType(WindowDragArea);
    await tester.drag(area, const Offset(60, 0));
    expect(calls.last, 'drag');
    await tester.tap(area);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(area);
    await tester.pumpAndSettle();
    expect(calls.last, 'doubleClick');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
