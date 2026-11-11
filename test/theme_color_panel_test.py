"""使用生产 NSColorPanel 实现验证实时回调、确认、取消和窗口关闭。"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ThemeColorPanelTest(unittest.TestCase):
    def test_native_panel_lifecycle(self):
        source = (ROOT / 'macos/Runner/MainFlutterWindow.swift').read_text()
        panel = source[source.index('private final class ThemeColorDialog:'):]
        harness = r'''
import Cocoa

func check(_ value: @autoclosure () -> Bool, _ message: String) {
  if !value() { fatalError(message) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 500),
  styleMask: [.titled], backing: .buffered, defer: false)
owner.orderFront(nil)
var changed: [Int64] = []
var replies: [Int64?] = []

func currentPanel() -> NSColorPanel {
  guard let panel = owner.attachedSheet as? NSColorPanel else {
    fatalError("未展示原生调色盘 sheet")
  }
  return panel
}
func button(_ title: String, in view: NSView) -> NSButton? {
  if let button = view as? NSButton, button.title == title { return button }
  return view.subviews.lazy.compactMap { button(title, in: $0) }.first
}
func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
private func dialog() -> ThemeColorDialog {
  ThemeColorDialog(initialColor: 0xFF6750A4,
    onChanged: { changed.append($0) }, completion: { replies.append($0) })
}

private let confirmed = dialog()
confirmed.present(relativeTo: owner)
settle()
let first = currentPanel()
check(!first.showsAlpha, "主题色应为不透明色")
check(first.mode == .wheel, "默认显示色轮")
first.color = NSColor(srgbRed: 0x12 / 255, green: 0x34 / 255, blue: 0x56 / 255, alpha: 1)
settle()
check(changed.last == 0xFF123456, "sRGB 实时颜色回调不正确")
button("确定", in: first.contentView!)!.performClick(nil)
settle()
check(replies.count == 1 && replies[0] == 0xFF123456, "确认返回所选颜色")
check(owner.attachedSheet == nil, "确认后解除 sheet")

private let cancelled = dialog()
cancelled.present(relativeTo: owner)
settle()
button("取消", in: currentPanel().contentView!)!.performClick(nil)
settle()
check(replies.count == 2 && replies[1] == nil, "取消应返回空值")
check(owner.attachedSheet == nil, "取消后解除 sheet")

private let closed = dialog()
closed.present(relativeTo: owner)
settle()
_ = currentPanel().delegate?.windowShouldClose?(currentPanel())
settle()
check(replies.count == 3 && replies[2] == nil, "关闭窗口应取消且只回调一次")
check(owner.attachedSheet == nil, "关闭后解除 sheet")
owner.orderOut(nil)
print("NSColorPanel 实时回调、确认、取消、关闭通过")
'''
        with tempfile.TemporaryDirectory(prefix='f7zip-color-panel-') as directory:
            root = Path(directory)
            swift = root / 'main.swift'
            swift.write_text(harness + '\n' + panel)
            executable = root / 'color-panel-test'
            compiled = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(root / 'modules'),
                                       str(swift), '-o', str(executable)],
                                      capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True,
                                    text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('NSColorPanel 实时回调、确认、取消、关闭通过', result.stdout)


if __name__ == '__main__':
    unittest.main()
