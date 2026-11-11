import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _window = MethodChannel('sevenzip/window');

bool get _macOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// 只让顶部留白响应拖动，避免工具按钮触发窗口移动。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!_macOS) return child;
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

class _WindowControlsState extends State<WindowControls> {
  bool _focused = true;
  bool _fullScreen = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    if (!_macOS) return;
    _window.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged') _update(call.arguments as Map);
    });
    _loadState();
  }

  Future<void> _loadState() async {
    final state = await _window.invokeMapMethod<String, dynamic>('state');
    if (state != null) _update(state);
  }

  void _update(Map state) {
    if (!mounted) return;
    setState(() {
      _focused = state['focused'] == true;
      _fullScreen = state['fullScreen'] == true;
    });
  }

  @override
  void dispose() {
    if (_macOS) _window.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_macOS) return const SizedBox.shrink();
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
