import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // 隐藏启动时也要持有窗口，否则 nib 的弱引用会释放 Flutter 引擎。
  var archiveWindow: NSWindow?
  var archiveChannel: FlutterMethodChannel?
  private var pendingRequests: [[String: Any]] = []
  private var flutterReady = false

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    NSApp.servicesProvider = self
    NSRegisterServicesProvider(self, "F7Zip")
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool != false {
      showMainWindow()
    }
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow()
    return true
  }

  func showMainWindow() {
    archiveWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  override func application(_ application: NSApplication, open urls: [URL]) {
    enqueue(action: "open", paths: urls.filter { $0.isFileURL }.map { $0.path })
  }

  @objc func performFinderAction(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    guard let action = userData, ["open", "extract", "extractHere", "extractTo", "compress", "compressZip"].contains(action) else {
      error.pointee = "无法识别 F7Zip 服务操作"
      return
    }
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    let legacyPaths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] ?? []
    let paths = urls.isEmpty ? legacyPaths : urls.map { $0.path }
    guard !paths.isEmpty else {
      error.pointee = "请先在 Finder 中选择文件或文件夹"
      return
    }
    enqueue(action: action, paths: paths)
  }

  private func enqueue(action: String, paths: [String]) {
    guard !paths.isEmpty else { return }
    let request: [String: Any] = ["action": action, "paths": paths]
    if flutterReady {
      archiveChannel?.invokeMethod("finderRequest", arguments: request)
    } else {
      // 冷启动时先保存请求，等待 Dart 安装消息处理器后再领取。
      pendingRequests.append(request)
    }
    if action == "open" || action == "compress" { showMainWindow() }
  }

  func takeFinderRequests() -> [[String: Any]] {
    if !flutterReady {
      // 服务端口已在启动阶段注册，此处只刷新菜单，避免重复注册引发异常。
      NSUpdateDynamicServices()
    }
    flutterReady = true
    defer { pendingRequests.removeAll() }
    return pendingRequests
  }
}
