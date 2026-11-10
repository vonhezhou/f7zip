import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  private var channel: FlutterMethodChannel?
  private var archiveMenu: ArchiveMenuTarget?

  override func awakeFromNib() {
    (NSApp.delegate as? AppDelegate)?.archiveWindow = self
    let controller = FlutterViewController()
    contentViewController = controller
    // 后台服务启动也需要加载视图并启动 Dart，不能等待窗口显示。
    contentView = controller.view
    setContentSize(NSSize(width: 1120, height: 740))
    minSize = NSSize(width: 860, height: 580)
    center()
    title = "F7Zip"
    RegisterGeneratedPlugins(registry: controller)
    let bridge = FlutterMethodChannel(name: "sevenzip/desktop", binaryMessenger: controller.engine.binaryMessenger)
    channel = bridge
    bridge.setMethodCallHandler { call, result in
      switch call.method {
      case "finderPassword":
        let arguments = call.arguments as? [String: String] ?? [:]
        let alert = NSAlert()
        alert.messageText = "压缩包密码"
        alert.informativeText = arguments["error"] ?? URL(fileURLWithPath: arguments["path"] ?? "").lastPathComponent
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        result(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
      case "finderError":
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = call.arguments as? String ?? "操作失败"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        result(nil)
      case "finderChooseFolder":
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "解压到此文件夹"
        NSApp.activate(ignoringOtherApps: true)
        result(panel.runModal() == .OK ? panel.url?.path : nil)
      case "setAppearance":
        let mode = call.arguments as? String ?? "system"
        NSApp.appearance = mode == "dark" ? NSAppearance(named: .darkAqua)
          : mode == "light" ? NSAppearance(named: .aqua) : nil
        result(nil)
      case "updateCommands":
        self.archiveMenu?.state = call.arguments as? [String: Bool] ?? [:]
        result(nil)
      case "setArchiveTitle":
        let path = call.arguments as? String ?? ""
        self.title = path.isEmpty ? "F7Zip" : URL(fileURLWithPath: path).lastPathComponent + " — F7Zip"
        self.representedURL = path.isEmpty ? nil : URL(fileURLWithPath: path)
        result(nil)
      case "recentArchives":
        result(UserDefaults.standard.stringArray(forKey: "recentArchives") ?? [])
      case "rememberArchive":
        if let path = call.arguments as? String {
          var paths = UserDefaults.standard.stringArray(forKey: "recentArchives") ?? []
          paths.removeAll { $0 == path }
          paths.insert(path, at: 0)
          paths = Array(paths.prefix(8))
          UserDefaults.standard.set(paths, forKey: "recentArchives")
          self.archiveMenu?.updateRecent(paths)
        }
        result(nil)
      case "loadSettings":
        result(UserDefaults.standard.dictionary(forKey: "preferences") ?? [:])
      case "saveSettings":
        guard let settings = call.arguments as? [String: Any] else {
          result(FlutterError(code: "settings", message: "设置格式无效", details: nil))
          return
        }
        UserDefaults.standard.set(settings, forKey: "preferences")
        result(nil)
      case "workspaceDirectory":
        do {
          let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
          let directory = support.appendingPathComponent("F7Zip/EditSessions", isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
          result(directory.path)
        } catch { result(FlutterError(code: "workspace", message: error.localizedDescription, details: nil)) }
      case "chooseApplication":
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: self) { response in result(response == .OK ? panel.url?.path : nil) }
      case "launchFile":
        self.launchFile(call.arguments as? [String: String] ?? [:], result: result)
      case "fileAssociations":
        result(self.associationStates())
      case "setFileAssociation":
        self.setAssociation(call.arguments as? [String: Any] ?? [:], result: result)
      case "openArchive", "chooseInputs", "chooseFolder":
        let panel = NSOpenPanel()
        panel.canChooseFiles = call.method != "chooseFolder"
        panel.canChooseDirectories = call.method != "openArchive"
        panel.allowsMultipleSelection = call.method == "chooseInputs"
        panel.prompt = call.method == "chooseFolder" ? "选择目标文件夹" : "选择"
        panel.beginSheetModal(for: self) { response in
          result(response == .OK ? panel.urls.map { $0.path } : [])
        }
      case "saveArchive":
        let panel = NSSavePanel()
        panel.nameFieldStringValue = call.arguments as? String ?? "Archive.zip"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: self) { response in
          result(response == .OK ? panel.url?.path : nil)
        }
      case "reveal":
        if let path = call.arguments as? String {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        result(nil)
      case "takeFinderRequests":
        result((NSApp.delegate as? AppDelegate)?.takeFinderRequests() ?? [])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    (NSApp.delegate as? AppDelegate)?.archiveChannel = bridge
    controller.engine.run(withEntrypoint: nil)
    super.awakeFromNib()
    DispatchQueue.main.async {
      let menu = ArchiveMenuTarget(channel: bridge)
      self.archiveMenu = menu
      menu.install()
      let preferences = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "," }
      preferences?.target = self
      preferences?.action = #selector(self.showPreferences(_:))
      preferences?.title = "设置…"
    }
  }

  @objc private func showPreferences(_ sender: Any?) {
    channel?.invokeMethod("showSettings", arguments: nil)
  }

  private let associationExtensions = ["zip", "7z", "rar", "tar", "gz", "xz", "bz2", "iso", "tgz", "tbz", "tbz2", "txz", "001", "z01", "r00", "zst", "cab", "dmg", "wim", "jar", "apk"]

  private func associationStates() -> [[String: Any]] {
    let backups = UserDefaults.standard.dictionary(forKey: "associationBackups") as? [String: String] ?? [:]
    return associationExtensions.map { ext in
      let type = UTType(filenameExtension: ext)
      let application = type.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
      let ours = application.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
      return ["extension": ext, "application": application?.deletingPathExtension().lastPathComponent ?? "未设置",
              "ours": ours, "canRestore": ours && type.flatMap { backups[$0.identifier] } != nil]
    }
  }

  private func setAssociation(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard let ext = arguments["extension"] as? String, associationExtensions.contains(ext),
          let type = UTType(filenameExtension: ext) else {
      result(FlutterError(code: "association", message: "无法识别文件后缀", details: nil))
      return
    }
    var backups = UserDefaults.standard.dictionary(forKey: "associationBackups") as? [String: String] ?? [:]
    let restore = arguments["restore"] as? Bool ?? false
    let current = NSWorkspace.shared.urlForApplication(toOpen: type)
    let target: URL
    if restore {
      guard let previous = backups[type.identifier], FileManager.default.fileExists(atPath: previous) else {
        result(FlutterError(code: "association", message: "先前的默认应用已不可用", details: nil))
        return
      }
      target = URL(fileURLWithPath: previous)
    } else {
      target = Bundle.main.bundleURL
    }
    NSWorkspace.shared.setDefaultApplication(at: target, toOpen: type) { error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(code: "association", message: error.localizedDescription, details: nil))
          return
        }
        if restore {
          backups.removeValue(forKey: type.identifier)
        } else if let current = current, Bundle(url: current)?.bundleIdentifier != Bundle.main.bundleIdentifier {
          backups[type.identifier] = current.path
        }
        UserDefaults.standard.set(backups, forKey: "associationBackups")
        result(self.associationStates())
      }
    }
  }

  private func launchFile(_ arguments: [String: String], result: @escaping FlutterResult) {
    guard let path = arguments["path"], FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "launch", message: "待打开的文件不存在", details: nil))
      return
    }
    let file = URL(fileURLWithPath: path)
    let application = arguments["application"] ?? ""
    if application.isEmpty {
      result(NSWorkspace.shared.open(file) ? nil : FlutterError(code: "launch", message: "没有可打开此文件的应用", details: nil))
      return
    }
    guard application.lowercased().hasSuffix(".app"), FileManager.default.fileExists(atPath: application) else {
      result(FlutterError(code: "launch", message: "请选择有效的 macOS .app 应用", details: nil))
      return
    }
    NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: application), configuration: NSWorkspace.OpenConfiguration()) { _, error in
      DispatchQueue.main.async { result(error.map { FlutterError(code: "launch", message: $0.localizedDescription, details: nil) }) }
    }
  }
}


private class ArchiveMenuTarget: NSObject, NSMenuItemValidation {
  let channel: FlutterMethodChannel
  let recent = NSMenu(title: "最近打开")
  var state: [String: Bool] = [:]

  init(channel: FlutterMethodChannel) { self.channel = channel; super.init() }

  private func item(_ title: String, _ command: String, _ key: String = "", shift: Bool = false) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: key)
    item.target = self
    item.representedObject = command
    item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
    return item
  }

  func install() {
    guard let root = NSApp.mainMenu else { return }
    let file = NSMenu(title: "文件")
    file.addItem(item("打开压缩包…", "open", "o"))
    file.addItem(item("新建压缩包…", "new", "n"))
    let recentItem = NSMenuItem(title: "最近打开", action: nil, keyEquivalent: "")
    recentItem.submenu = recent
    file.addItem(recentItem)
    file.addItem(.separator())
    file.addItem(item("解压到…", "extract", "e"))
    file.addItem(item("添加文件…", "add", "a", shift: true))
    file.addItem(item("新建文件夹…", "mkdir", "n", shift: true))
    file.addItem(item("测试压缩包", "test"))
    file.addItem(.separator())
    file.addItem(item("属性", "properties", "i"))
    file.addItem(item("关闭压缩包", "close", "w"))
    let fileRoot = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
    fileRoot.submenu = file
    root.insertItem(fileRoot, at: 1)
    if let edit = root.items.first(where: { $0.title == "Edit" })?.submenu {
      edit.addItem(.separator())
      edit.addItem(item("重命名…", "rename"))
      edit.addItem(item("从压缩包删除…", "remove", "\u{8}"))
      edit.addItem(item("编辑压缩包内文件", "edit"))
    }
    if let view = root.items.first(where: { $0.title == "View" })?.submenu {
      view.insertItem(item("文件树", "tree"), at: 0)
      view.insertItem(item("后退", "back", "["), at: 1)
      view.insertItem(item("前进", "forward", "]"), at: 2)
      view.insertItem(item("查看文件", "view"), at: 3)
      view.insertItem(.separator(), at: 4)
    }
    updateRecent(UserDefaults.standard.stringArray(forKey: "recentArchives") ?? [])
  }

  func updateRecent(_ paths: [String]) {
    recent.removeAllItems()
    for path in paths {
      let item = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = path
      item.toolTip = path
      recent.addItem(item)
    }
  }

  @objc private func performCommand(_ sender: NSMenuItem) {
    if let command = sender.representedObject as? String {
      channel.invokeMethod("archiveCommand", arguments: command)
    }
  }

  @objc private func openRecent(_ sender: NSMenuItem) {
    if let path = sender.representedObject as? String {
      channel.invokeMethod("finderRequest", arguments: ["action": "open", "paths": [path]])
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let command = menuItem.representedObject as? String else { return true }
    if command == "tree" { menuItem.state = state["treeVisible"] == true ? .on : .off }
    if menuItem.action == #selector(openRecent(_:)) { return state["open"] ?? false }
    return state[command] ?? false
  }
}
