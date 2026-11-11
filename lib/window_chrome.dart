import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

const _window = MethodChannel('sevenzip/window');

bool get windowControlsOnLeft =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

bool get windowControlsOnRight =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

/// macOS 使用现有原生通道，其他桌面平台由插件隐藏系统标题栏。
Future<void> initializeDesktopWindow() async {
  if (!windowControlsOnRight) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'F7Zip',
      size: Size(1120, 740),
      minimumSize: Size(860, 580),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}

/// 只让顶部留白响应拖动，避免工具按钮触发窗口移动。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (windowControlsOnRight) return DragToMoveArea(child: child);
    if (!windowControlsOnLeft) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => _window.invokeMethod<void>('drag'),
      onDoubleTap: () => _window.invokeMethod<void>('doubleClick'),
      child: child,
    );
  }
}

class WindowControls extends StatefulWidget {
  const WindowControls({super.key});

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> with WindowListener {
  bool _focused = true;
  bool _fullScreen = false;
  bool _maximized = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    if (windowControlsOnLeft) {
      _window.setMethodCallHandler((call) async {
        if (call.method == 'stateChanged') _update(call.arguments as Map);
      });
      _loadState();
    } else if (windowControlsOnRight) {
      windowManager.addListener(this);
      _loadDesktopState();
    }
  }

  Future<void> _loadState() async {
    final state = await _window.invokeMapMethod<String, dynamic>('state');
    if (state != null) _update(state);
  }

  Future<void> _loadDesktopState() async {
    final state = await Future.wait([
      windowManager.isFocused(),
      windowManager.isMaximized(),
    ]);
    if (!mounted) return;
    setState(() {
      _focused = state[0];
      _maximized = state[1];
    });
  }

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    await _loadDesktopState();
  }

  @override
  void onWindowFocus() => setState(() => _focused = true);

  @override
  void onWindowBlur() => setState(() => _focused = false);

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  void onWindowRestore() => _loadDesktopState();

  void _update(Map state) {
    if (!mounted) return;
    setState(() {
      _focused = state['focused'] == true;
      _fullScreen = state['fullScreen'] == true;
    });
  }

  @override
  void dispose() {
    if (windowControlsOnLeft) _window.setMethodCallHandler(null);
    if (windowControlsOnRight) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (windowControlsOnRight) return _desktopControls();
    if (!windowControlsOnLeft) return const SizedBox.shrink();
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _button('关闭窗口', 'close', const Color(0xFFFF5F57), Icons.close),
            _button('最小化窗口', 'minimize', const Color(0xFFFFBD2E), Icons.remove),
            _button(
              _fullScreen ? '退出全屏' : '进入全屏',
              'fullScreen',
              const Color(0xFF28C840),
              _fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktopControls() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _desktopButton('最小化窗口', Icons.remove, windowManager.minimize),
      _desktopButton(
        _maximized ? '还原窗口' : '最大化窗口',
        _maximized ? Icons.filter_none : Icons.crop_square,
        _toggleMaximize,
      ),
      _desktopButton('关闭窗口', Icons.close, windowManager.close, close: true),
    ],
  );

  Widget _desktopButton(
    String label,
    IconData icon,
    VoidCallback action, {
    bool close = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: TextButton(
        onPressed: action,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(46, 52)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (close && states.contains(WidgetState.hovered)) {
              return Colors.white;
            }
            return colors.onSurface.withValues(alpha: _focused ? 1 : .55);
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (close && states.contains(WidgetState.hovered)) {
              return const Color(0xFFC42B1C);
            }
            if (states.contains(WidgetState.pressed)) {
              return colors.onSurface.withValues(alpha: .12);
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return colors.onSurface.withValues(alpha: .08);
            }
            return Colors.transparent;
          }),
        ),
        child: Icon(icon, size: 15, semanticLabel: label),
      ),
    );
  }

  Widget _button(String label, String action, Color color, IconData icon) {
    final active = _focused || _hovered;
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _window.invokeMethod<void>(action),
          // 点击区大于圆点，兼顾视觉尺寸和操作容错。
          child: SizedBox(
            width: 20,
            height: 32,
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: active
                      ? color
                      : Theme.of(context).colorScheme.outlineVariant,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.black.withValues(alpha: .12),
                    width: .5,
                  ),
                ),
                child: _hovered
                    ? Icon(
                        icon,
                        size: 10,
                        color: Colors.black.withValues(alpha: .65),
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
