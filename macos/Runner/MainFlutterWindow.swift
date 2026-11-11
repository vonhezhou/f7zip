import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import QuickLookUI
import PDFKit
import ImageIO

class MainFlutterWindow: NSWindow {
  private let passwordStore = ArchivePasswordStore()
  private let passwordQueue = DispatchQueue(label: "dev.von.f7zip.passwords")
  private var channel: FlutterMethodChannel?
  private var archiveMenu: ArchiveMenuTarget?
  private var dragSources: [String: ArchiveFileDragSource] = [:]
  private var dragEventMonitor: Any?
  private var lastDragEvent: NSEvent?
  private var nestedArchiveDirectories = Set<URL>()
  private var previewDirectories = Set<URL>()
  private var archivePreviews: [String: ArchivePreviewWindowController] = [:]
  private var previewTerminationObserver: NSObjectProtocol?

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
    previewTerminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      self?.cleanupArchivePreviews()
      self?.cleanupNestedArchives()
    }
    bridge.setMethodCallHandler { call, result in
      switch call.method {
      case "createNestedArchiveDirectory":
        do {
          guard self.nestedArchiveDirectories.count < 8 else { throw ArchivePreviewError.resourceLimit }
          let directory = FileManager.default.temporaryDirectory.appendingPathComponent("f7zip-nested-" + UUID().uuidString, isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
          self.nestedArchiveDirectories.insert(directory)
          result(directory.path)
        } catch { result(FlutterError(code: "nested", message: error.localizedDescription, details: nil)) }
      case "discardNestedArchiveDirectory":
        do {
          if let path = call.arguments as? String { try self.discardNestedArchiveDirectory(URL(fileURLWithPath: path, isDirectory: true)) }
          result(nil)
        } catch { result(FlutterError(code: "nested", message: error.localizedDescription, details: nil)) }
      case "createArchivePreviewDirectory":
        self.createArchivePreviewDirectory(result: result)
      case "discardArchivePreviewDirectory":
        do {
          if let path = call.arguments as? String { try self.discardArchivePreviewDirectory(URL(fileURLWithPath: path, isDirectory: true)) }
          result(nil)
        } catch { result(FlutterError(code: "preview", message: error.localizedDescription, details: nil)) }
      case "showArchivePreview":
        self.showArchivePreview(call.arguments as? [String: String] ?? [:], result: result)
      case "closeArchivePreviews":
        self.closeArchivePreviews(call.arguments as? [String] ?? [])
        result(nil)
      case "startArchiveDrag":
        self.startArchiveDrag(call.arguments as? [String: Any] ?? [:], view: controller.view, result: result)
      case "listArchivePasswords", "saveArchivePassword", "deleteArchivePassword", "archivePasswordCandidates":
        let arguments = call.arguments as? [String: Any] ?? [:]
        let enabled = UserDefaults.standard.dictionary(forKey: "preferences")?["autoTryPasswords"] as? Bool == true
        self.passwordQueue.async {
          do {
            let response: [String]
            switch call.method {
            case "saveArchivePassword":
              guard let name = arguments["name"] as? String, let password = arguments["password"] as? String else { throw ArchivePasswordStore.StoreError.invalidInput }
              try self.passwordStore.save(name: name, password: password, replace: arguments["replace"] as? Bool == true)
              response = try self.passwordStore.names()
            case "deleteArchivePassword":
              guard let name = arguments["name"] as? String else { throw ArchivePasswordStore.StoreError.invalidInput }
              try self.passwordStore.delete(name: name)
              response = try self.passwordStore.names()
            case "archivePasswordCandidates": response = enabled ? try self.passwordStore.candidates() : []
            default: response = try self.passwordStore.names()
            }
            DispatchQueue.main.async { result(response) }
          } catch {
            DispatchQueue.main.async { result(FlutterError(code: "keychain", message: error.localizedDescription, details: nil)) }
          }
        }
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
      case "finderExtractionConflict":
        let arguments = call.arguments as? [String: Any] ?? [:]
        let paths = arguments["paths"] as? [String] ?? []
        let alert = NSAlert()
        alert.messageText = "解压目标存在同名项目"
        alert.informativeText = "选择的方式应用于本次解压。跳过、合并与替换会合并同名文件夹，替换仅适用于普通文件。\n\n" + paths.prefix(8).joined(separator: "\n")
        let choices = [("取消解压", ""), ("跳过同名文件", "skip"), ("自动改名", "rename"), ("合并目录", "merge"), ("替换同名文件", "overwrite")]
        for choice in choices { alert.addButton(withTitle: choice.0) }
        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        var choice = choices.indices.contains(index) ? choices[index].1 : ""
        if choice == "overwrite" {
          let confirmation = NSAlert()
          confirmation.messageText = "替换已有文件？"
          confirmation.informativeText = "本次解压中同名的普通文件将被替换。文件夹会合并，其他文件会保留。"
          confirmation.addButton(withTitle: "取消")
          confirmation.addButton(withTitle: "确认替换")
          if confirmation.runModal() != .alertSecondButtonReturn { choice = "" }
        }
        result(choice.isEmpty ? nil : choice)
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
      case "importTheme":
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入主题"
        panel.beginSheetModal(for: self) { response in
          result(response == .OK ? panel.url?.path : nil)
        }
      case "exportTheme":
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "F7Zip-theme.json"
        panel.canCreateDirectories = true
        panel.prompt = "导出主题"
        panel.beginSheetModal(for: self) { response in
          result(response == .OK ? panel.url?.path : nil)
        }
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
      case "openArchive", "chooseArchives", "chooseInputs", "chooseFolder", "chooseChecksumFiles":
        let panel = NSOpenPanel()
        panel.canChooseFiles = call.method != "chooseFolder"
        panel.canChooseDirectories = !["openArchive", "chooseArchives", "chooseChecksumFiles"].contains(call.method)
        panel.allowsMultipleSelection = ["chooseInputs", "chooseArchives", "chooseChecksumFiles"].contains(call.method)
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
    dragEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
      if event.window === self { self?.lastDragEvent = event }
      return event
    }
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

  private let associationExtensions = ["zip", "zipx", "7z", "rar", "tar", "gz", "xz", "bz2", "iso", "tgz", "tbz", "tbz2", "txz", "001", "z01", "r00", "zst", "cab", "dmg", "wim", "jar", "apk"]

  deinit {
    if let observer = previewTerminationObserver { NotificationCenter.default.removeObserver(observer) }
    if let monitor = dragEventMonitor { NSEvent.removeMonitor(monitor) }
  }

  private func discardNestedArchiveDirectory(_ directory: URL) throws {
    guard nestedArchiveDirectories.contains(directory) else { return }
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    nestedArchiveDirectories.remove(directory)
  }

  private func cleanupNestedArchives() {
    for directory in Array(nestedArchiveDirectories) { try? discardNestedArchiveDirectory(directory) }
  }

  private func createArchivePreviewDirectory(result: @escaping FlutterResult) {
    guard previewDirectories.count < 2 else {
      result(FlutterError(code: "preview", message: "最多同时打开两个预览，请先关闭已有预览", details: nil))
      return
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("f7zip-preview-" + UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      previewDirectories.insert(directory)
      result(directory.path)
    } catch { result(FlutterError(code: "preview", message: error.localizedDescription, details: nil)) }
  }

  private func discardArchivePreviewDirectory(_ directory: URL) throws {
    guard previewDirectories.contains(directory) else { return }
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    previewDirectories.remove(directory)
  }

  private func showArchivePreview(_ arguments: [String: String], result: @escaping FlutterResult) {
    guard let id = arguments["id"], let path = arguments["path"], let root = arguments["directory"],
          let kind = arguments["kind"], let title = arguments["title"], archivePreviews[id] == nil else {
      result(FlutterError(code: "preview", message: "预览请求无效", details: nil))
      return
    }
    let directory = URL(fileURLWithPath: root, isDirectory: true)
    let file = URL(fileURLWithPath: path)
    guard previewDirectories.contains(directory), file.deletingLastPathComponent() == directory else {
      result(FlutterError(code: "preview", message: "预览文件不在已登记的暂存目录", details: nil))
      return
    }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ArchivePreviewError.invalidFile }
      let limit = kind == "text" ? 4 * 1024 * 1024 : 256 * 1024 * 1024
      guard let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(limit) else { throw ArchivePreviewError.resourceLimit }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
      if kind == "image" { try validatePreviewImage(file) }
      if kind == "pdf" {
        guard let document = PDFDocument(url: file) else { throw ArchivePreviewError.invalidFile }
        guard document.pageCount <= 1000 else { throw ArchivePreviewError.resourceLimit }
      }
      guard ["text", "image", "pdf", "audio", "video"].contains(kind),
            let controller = ArchivePreviewWindowController(file: file, title: title) else { throw ArchivePreviewError.invalidFile }
      controller.onClosed = { [weak self] in
        guard let self = self else { return }
        self.archivePreviews.removeValue(forKey: id)
        var response = ["id": id]
        do { try self.discardArchivePreviewDirectory(directory) }
        catch { response["error"] = error.localizedDescription }
        self.channel?.invokeMethod("archivePreviewClosed", arguments: response)
      }
      archivePreviews[id] = controller
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    } catch { result(FlutterError(code: "preview", message: error.localizedDescription, details: nil)) }
  }

  private func validatePreviewImage(_ file: URL) throws {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ArchivePreviewError.invalidFile }
    let count = CGImageSourceGetCount(source)
    guard count > 0 && count <= 512 else { throw ArchivePreviewError.resourceLimit }
    var pixels: UInt64 = 0
    for index in 0..<count {
      guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw ArchivePreviewError.invalidFile }
      let w = width.uint64Value, h = height.uint64Value
      guard w > 0 && h > 0 && w <= 16384 && h <= 16384 && w * h <= 40_000_000 else { throw ArchivePreviewError.resourceLimit }
      pixels += w * h
      guard pixels <= 80_000_000 else { throw ArchivePreviewError.resourceLimit }
    }
  }

  private func closeArchivePreviews(_ ids: [String]) {
    for id in ids { archivePreviews[id]?.close() }
  }

  private func cleanupArchivePreviews() {
    closeArchivePreviews(Array(archivePreviews.keys))
    for directory in Array(previewDirectories) { try? discardArchivePreviewDirectory(directory) }
  }

  private func startArchiveDrag(_ arguments: [String: Any], view: NSView, result: @escaping FlutterResult) {
    guard let sessionId = arguments["session"] as? String,
          let items = arguments["items"] as? [[String: Any]], !items.isEmpty,
          let channel = channel, let event = lastDragEvent,
          event.type == .leftMouseDragged || event.type == .leftMouseDown,
          NSEvent.pressedMouseButtons & 1 != 0 else {
      result(FlutterError(code: "drag", message: "请按住鼠标从文件名开始拖动", details: nil))
      return
    }
    var identifiers = Set<String>()
    for item in items {
      guard let identifier = item["id"] as? String, identifiers.insert(identifier).inserted,
            let name = item["name"] as? String, !name.isEmpty, name != ".", name != "..",
            !name.contains("/"), !name.contains("\0"), item["directory"] is Bool else {
        result(FlutterError(code: "drag", message: "拖出项目名称无效", details: nil))
        return
      }
    }
    let source = ArchiveFileDragSource(sessionId: sessionId, channel: channel, count: items.count)
    source.onFinished = { [weak self] in self?.dragSources.removeValue(forKey: sessionId) }
    dragSources[sessionId] = source
    let point = view.convert(event.locationInWindow, from: nil)
    let draggingItems = items.enumerated().map { index, item -> NSDraggingItem in
      let type = item["directory"] as? Bool == true ? UTType.folder.identifier : UTType.data.identifier
      let provider = NSFilePromiseProvider(fileType: type, delegate: source)
      provider.userInfo = item
      let dragging = NSDraggingItem(pasteboardWriter: provider)
      let icon = NSWorkspace.shared.icon(for: item["directory"] as? Bool == true ? UTType.folder : UTType.data)
      let offset = CGFloat(min(index, 4)) * 4
      dragging.setDraggingFrame(NSRect(x: point.x - 16 + offset, y: point.y - 16 - offset, width: 32, height: 32), contents: icon)
      return dragging
    }
    let session = view.beginDraggingSession(with: draggingItems, event: event, source: source)
    session.draggingFormation = .stack
    session.animatesToStartingPositionsOnCancelOrFail = true
    result(nil)
  }

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
    file.addItem(item("批量解压…", "batchExtract"))
    file.addItem(item("批量测试…", "batchTest"))
    file.addItem(item("任务队列", "tasks"))
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
      view.insertItem(item("内置预览", "preview"), at: 3)
      view.insertItem(item("查看文件", "view"), at: 4)
      view.insertItem(item("进入子压缩包", "nested"), at: 5)
      view.insertItem(item("返回父压缩包", "parentArchive"), at: 6)
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

// Finder 确定落点后再请求数据，拖动取消时无需创建解压临时文件。
private class ArchiveFileDragSource: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
  let sessionId: String
  let channel: FlutterMethodChannel
  let count: Int
  var onFinished: (() -> Void)?
  private var pending = 0
  private var completed = Set<String>()
  private var ended = false
  private var cancelled = false
  private var expiry: Timer?

  init(sessionId: String, channel: FlutterMethodChannel, count: Int) {
    self.sessionId = sessionId
    self.channel = channel
    self.count = count
  }

  deinit { expiry?.invalidate() }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    return context == .outsideApplication ? .copy : []
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    ended = true
    cancelled = operation.isEmpty
    channel.invokeMethod("archiveDragEnded", arguments: ["session": sessionId, "cancelled": cancelled])
    finishIfReady()
    if !cancelled && completed.count < count { scheduleExpiry() }
  }

  func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
    return (filePromiseProvider.userInfo as? [String: Any])?["name"] as? String ?? "Extracted"
  }

  func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
    DispatchQueue.main.async {
      guard let item = (filePromiseProvider.userInfo as? [String: Any])?["id"] as? String else {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: "拖出请求无效"]))
        return
      }
      self.pending += 1
      self.channel.invokeMethod("writeArchivePromise", arguments: ["session": self.sessionId, "item": item, "destination": url.path]) { value in
        var error: Error?
        if let failure = value as? FlutterError {
          error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: failure.message ?? "拖出解压失败"])
        } else if (value as? [String: Any])?["ok"] as? Bool != true {
          error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: "拖出请求已失效"])
        }
        completionHandler(error)
        self.pending -= 1
        self.completed.insert(item)
        self.finishIfReady()
      }
    }
  }

  private func finishIfReady() {
    if ended && pending == 0 && (cancelled || completed.count == count) {
      expiry?.invalidate()
      onFinished?()
    }
  }

  private func scheduleExpiry() {
    expiry?.invalidate()
    expiry = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      if self.pending > 0 { self.scheduleExpiry() }
      else { self.onFinished?() }
    }
  }
}

private enum ArchivePreviewError: LocalizedError {
  case invalidFile
  case resourceLimit
  var errorDescription: String? {
    switch self {
    case .invalidFile: return "文件损坏或当前预览组件无法读取"
    case .resourceLimit: return "文件超过预览资源上限"
    }
  }
}

private class ArchivePreviewItem: NSObject, QLPreviewItem {
  let previewItemURL: URL?
  let previewItemTitle: String?
  init(file: URL, title: String) { previewItemURL = file; previewItemTitle = title }
}

private class ArchivePreviewWindowController: NSWindowController, NSWindowDelegate {
  private let preview: QLPreviewView
  var onClosed: (() -> Void)?

  init?(file: URL, title: String) {
    let frame = NSRect(x: 0, y: 0, width: 760, height: 560)
    guard let preview = QLPreviewView(frame: frame, style: .normal) else { return nil }
    self.preview = preview
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = title + " — 内置预览"
    window.minSize = NSSize(width: 420, height: 320)
    window.isReleasedWhenClosed = false
    window.contentView = preview
    window.delegate = self
    preview.autostarts = false
    preview.shouldCloseWithWindow = false
    preview.previewItem = ArchivePreviewItem(file: file, title: title)
    window.center()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func windowWillClose(_ notification: Notification) {
    preview.close()
    onClosed?()
  }
}
