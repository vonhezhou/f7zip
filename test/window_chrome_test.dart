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

  testWidgets(
    'Windows/Linux 控件切换最大化与还原并响应系统状态',
    (tester) async {
      const channel = MethodChannel('window_manager');
      var maximized = false;
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        switch (call.method) {
          case 'isFocused':
            return true;
          case 'isMaximized':
            return maximized;
          case 'maximize':
            maximized = true;
          case 'unmaximize':
            maximized = false;
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WindowControls())),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('进入全屏'), findsNothing);
      await tester.tap(find.byTooltip('最小化窗口'));
      await tester.tap(find.byTooltip('最大化窗口'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('还原窗口'), findsOneWidget);
      await tester.tap(find.byTooltip('还原窗口'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('最大化窗口'), findsOneWidget);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onEvent', {'eventName': 'maximize'}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('还原窗口'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭窗口'));
      // 主题切换后复查图标实际使用的颜色，防止深色主题中出现黑色控件。
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(body: WindowControls()),
        ),
      );
      await tester.pumpAndSettle();
      final closeIcon = find.descendant(
        of: find.byType(WindowControls),
        matching: find.byIcon(Icons.close),
      );
      final iconContext = tester.element(closeIcon);
      final foreground = Theme.of(iconContext).colorScheme.onSurface;
      expect(IconTheme.of(iconContext).color, foreground);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onEvent', {'eventName': 'blur'}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(
        IconTheme.of(iconContext).color,
        foreground.withValues(alpha: .55),
      );
      expect(
        calls,
        containsAllInOrder(['minimize', 'maximize', 'unmaximize', 'close']),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'Windows/Linux 标题区支持拖动和双击最大化还原',
    (tester) async {
      const channel = MethodChannel('window_manager');
      var maximized = false;
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        switch (call.method) {
          case 'isMaximized':
            return maximized;
          case 'maximize':
            maximized = true;
          case 'unmaximize':
            maximized = false;
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WindowDragArea(child: SizedBox(width: 300, height: 52)),
          ),
        ),
      );
      final area = find.byType(WindowDragArea);
      await tester.drag(area, const Offset(60, 0));
      expect(calls, contains('startDragging'));
      for (final action in ['maximize', 'unmaximize']) {
        await tester.tap(area);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(area);
        await tester.pumpAndSettle();
        expect(calls.last, action);
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    '桌面初始化按平台隐藏标题栏并设置最小尺寸',
    (tester) async {
      const channel = MethodChannel('window_manager');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method.startsWith('is')) return false;
        if (call.method == 'getBounds') {
          return {'x': 0.0, 'y': 0.0, 'width': 1120.0, 'height': 740.0};
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      const screenChannel = MethodChannel(
        'dev.leanflutter.plugins/screen_retriever',
      );
      const display = {
        'id': 'test-display',
        'size': {'width': 1920.0, 'height': 1080.0},
        'visiblePosition': {'dx': 0.0, 'dy': 0.0},
      };
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        screenChannel,
        (call) async {
          switch (call.method) {
            case 'getPrimaryDisplay':
              return display;
            case 'getAllDisplays':
              return {
                'displays': [display],
              };
            case 'getCursorScreenPoint':
              return {'dx': 100.0, 'dy': 100.0};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          screenChannel,
          null,
        ),
      );
      await initializeDesktopWindow();
      await tester.pump();
      if (windowControlsOnLeft) {
        expect(calls, isEmpty);
      } else {
        expect(
          calls.map((call) => call.method),
          containsAllInOrder([
            'ensureInitialized',
            'waitUntilReadyToShow',
            'setTitleBarStyle',
            'setMinimumSize',
            'show',
            'focus',
          ]),
        );
        expect(
          calls
              .singleWhere((call) => call.method == 'setTitleBarStyle')
              .arguments,
          {'titleBarStyle': 'hidden', 'windowButtonVisibility': false},
        );
        expect(
          calls
              .singleWhere((call) => call.method == 'setMinimumSize')
              .arguments,
          allOf(containsPair('width', 860.0), containsPair('height', 580.0)),
        );
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
