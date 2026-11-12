import AppKit
import SwiftUI
import Combine
import Carbon

private extension NSToolbarItem.Identifier {
    static let bridgeRefresh = Self("MicBridge.Refresh")
    static let bridgeConnect = Self("MicBridge.Connect")
    static let bridgeRecord = Self("MicBridge.Record")
}

final class BridgeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    private let preview = CommandLine.arguments.contains("--ui-preview")
    private var model: BridgeController!
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var helpWindow: NSWindow?
    private let settingsSelection = BridgeSettingsSelection()
    private var workspace: NSHostingController<BridgeWindow>!
    private var item: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()
    private var choosingExit = false
    private var canRefresh: Bool { !model.preview && !model.refreshing && !model.active && !model.closing && !model.captureBlocked && !model.importing && !model.hfpBusy }
    private var canRecord: Bool { model.canToggleRecording }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: .activateIgnoringOtherApps); NSApp.terminate(nil); return
        }
        model = BridgeController(preview: preview)
        model.showWindowAction = { [weak self] in self?.showWindow() }
        model.finishedTermination = { NSApp.reply(toApplicationShouldTerminate: $0) }
        installMenus()
        NotificationCenter.default.publisher(for: .bridgeSettingsRequested).receive(on: RunLoop.main).sink { [weak self] _ in
            self?.settingsSelection.page = .diagnostics; self?.showSettings()
        }.store(in: &subscriptions)
        workspace = NSHostingController(rootView: BridgeWindow(model: model))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 925, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = preview ? "MicBridge · 界面预览" : "MicBridge"
        window.identifier = NSUserInterfaceItemIdentifier("MicBridge.MainWindow")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .windowBackgroundColor
        window.delegate = self; window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.collectionBehavior.insert(.fullScreenPrimary)
        let toolbar = NSToolbar(identifier: preview ? "MicBridge.PreviewToolbar.Studio4" : "MicBridge.MainToolbar.Studio4")
        toolbar.delegate = self; toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true; toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        window.toolbar = toolbar
        // Installing the content/toolbar can resize a window to its intrinsic minimum.
        // Restore the user's frame only after the complete native chrome is installed.
        window.contentMinSize = NSSize(width: 420, height: 360)
        let frameName = preview ? "MicBridge.PreviewWindow.Reference4" : "MicBridge.MainWindow.Reference4"
        let savedWidth = UserDefaults.standard.string(forKey: "NSWindow Frame \(frameName)")?
            .split(separator: " ").dropFirst(2).first.flatMap { Double($0) }
        let restored = window.setFrameUsingName(frameName)
        if !restored || (savedWidth.map { $0 < 420 } ?? false) {
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 925, height: 680)), display: false); window.center()
        }
        window.setFrameAutosaveName(frameName)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MicBridge")
        item.button?.image?.isTemplate = true
        item.button?.target = self; item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            self?.item.button?.toolTip = "MicBridge · " + phase.title
            self?.item.button?.setAccessibilityLabel("MicBridge · " + phase.title)
        }.store(in: &subscriptions)
        model.$recording.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] recording in
            self?.item.button?.title = recording ? " ●" : ""
        }.store(in: &subscriptions)
        model.objectWillChange.throttle(for: .milliseconds(150), scheduler: RunLoop.main, latest: true).sink { [weak self] in
            DispatchQueue.main.async { self?.updateToolbar() }
        }.store(in: &subscriptions)
        updateToolbar()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
        if preview || !loginLaunch || model.showWindow { showWindow() }
        else { NSApp.setActivationPolicy(.accessory) }
        if !preview { model.refresh() }
    }

    private func installMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title); root.submenu = submenu; bar.addItem(root); return submenu
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers; entry.target = target
            menu.addItem(entry); return entry
        }
        let app = menu("MicBridge")
        add(app, "关于 MicBridge", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "设置…", #selector(showSettings), ",", target: self)
        app.addItem(.separator())
        let services = NSMenu(title: "服务"), servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(.separator())
        add(app, "隐藏 MicBridge", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(app, "显示全部", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "退出 MicBridge", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("文件")
        add(file, "导入 SPP 数据…", #selector(importCapture), "o", target: self)
        file.addItem(.separator())
        add(file, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("编辑")
        add(edit, "撤销", Selector(("undo:")), "z")
        add(edit, "重做", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), "x")
        add(edit, "复制", #selector(NSText.copy(_:)), "c")
        add(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        add(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        let capture = menu("录音")
        add(capture, "开始录音", #selector(toggleRecording), "r", target: self)
        add(capture, "设为系统输入", #selector(makeSystemInput), "m", [.command, .option], target: self)
        capture.addItem(.separator())
        add(capture, "连接 SPP", #selector(connectOrDisconnect), "k", target: self)
        add(capture, "刷新设备列表", #selector(refreshDevices), "r", [.command, .shift], target: self)
        let view = menu("显示")
        add(view, "隐藏工具栏", #selector(toggleToolbar), "t", [.command, .option], target: self)
        add(view, "自定工具栏…", #selector(customizeToolbar), "t", [.command, .option, .shift], target: self)
        let windows = menu("窗口")
        add(windows, "显示主窗口", #selector(showWindow), "0", target: self)
        add(windows, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "缩放", #selector(NSWindow.performZoom(_:)))
        add(windows, "进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        windows.addItem(.separator())
        add(windows, "前置全部窗口", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = windows
        let help = menu("帮助")
        add(help, "MicBridge 使用说明", #selector(showHelp), "?", target: self)
        NSApp.helpMenu = help
        NSApp.mainMenu = bar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.bridgeRefresh, .bridgeConnect, .bridgeRecord, .flexibleSpace, .space]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let metadata: (String, String, Selector)
        switch id {
        case .bridgeRefresh: metadata = ("刷新列表", "arrow.clockwise", #selector(refreshDevices))
        case .bridgeConnect: metadata = ("连接 SPP", "antenna.radiowaves.left.and.right", #selector(connectOrDisconnect))
        case .bridgeRecord: metadata = ("开始录音", "record.circle", #selector(toggleRecording))
        default: return nil
        }
        let entry = NSToolbarItem(itemIdentifier: id)
        entry.label = metadata.0; entry.paletteLabel = metadata.0; entry.toolTip = metadata.0
        entry.image = NSImage(systemSymbolName: metadata.1, accessibilityDescription: metadata.0)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        entry.target = self; entry.action = metadata.2
        return entry
    }
    private func updateToolbar() {
        for entry in window?.toolbar?.items ?? [] {
            if entry.itemIdentifier == .bridgeRecord {
                entry.label = model.recordingButtonTitle
                entry.image = NSImage(systemSymbolName: model.recording ? "stop.circle" : "record.circle", accessibilityDescription: entry.label)
            } else if entry.itemIdentifier == .bridgeConnect {
                entry.label = (model.closing || model.exitPending) ? "正在退出…" : model.active ? "断开 SPP…" : "连接 SPP"
            }
            let keys: [NSToolbarItem.Identifier: String] = [.bridgeRefresh: "⇧⌘R", .bridgeConnect: "⌘K", .bridgeRecord: "⌘R"]
            entry.toolTip = entry.label + "（" + (keys[entry.itemIdentifier] ?? "") + "）"
            entry.isEnabled = commandEnabled(entry.action)
        }
    }
    private func commandEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(refreshDevices): return canRefresh
        case #selector(toggleRecording): return canRecord
        case #selector(makeSystemInput): return model.systemMicEnabled
        case #selector(connectOrDisconnect): return model.active ? (!model.closing && !model.exitPending) : model.canConnect
        case #selector(importCapture): return !model.active && !model.hfpBusy && !model.importing && !model.preview
        default: return true
        }
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { commandEnabled(item.action) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleRecording): menuItem.title = model.recordingButtonTitle
        case #selector(connectOrDisconnect): menuItem.title = (model.closing || model.exitPending) ? "正在退出 SPP…" : model.active ? "断开 SPP…" : "连接 SPP"
        case #selector(toggleToolbar): menuItem.title = window.toolbar?.isVisible == true ? "隐藏工具栏" : "显示工具栏"
        default: break
        }
        return commandEnabled(menuItem.action)
    }

    @objc func showWindow() {
        guard window != nil else { return }
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showSettings() {
        model.updateLaunchStatus()
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            settings.title = "MicBridge 设置"; settings.isReleasedWhenClosed = false
            settings.contentViewController = NSHostingController(rootView: BridgeSettingsView(model: model, selection: settingsSelection))
            settings.minSize = NSSize(width: 580, height: 520)
            let frameName = preview ? "MicBridge.PreviewSettings.Tabs" : "MicBridge.Settings.Tabs"
            let restored = settings.setFrameUsingName(frameName)
            settings.setFrameAutosaveName(frameName)
            if !restored { settings.center() }
            settingsWindow = settings
        }
        NSApp.setActivationPolicy(.regular); settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleToolbar() { window.toggleToolbarShown(nil) }
    @objc private func customizeToolbar() { showWindow(); window.runToolbarCustomizationPalette(nil) }
    @objc private func refreshDevices() { if canRefresh { model.refresh() } }
    @objc private func makeSystemInput() { model.useSystemMicrophoneAsDefault() }
    @objc private func toggleRecording() { if canRecord { model.toggleRecording() } }
    @objc private func connectOrDisconnect() {
        guard commandEnabled(#selector(connectOrDisconnect)) else { return }
        if model.active {
            showWindow()
            NotificationCenter.default.post(name: .bridgeDisconnectRequested, object: nil)
        } else { model.connect() }
    }
    @objc private func importCapture() { if commandEnabled(#selector(importCapture)) { showWindow(); model.importCapture() } }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { showWindow(); return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            let menu = NSMenu()
            func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
                entry.keyEquivalentModifierMask = modifiers
                entry.target = target ?? self
                menu.addItem(entry)
            }
            add("打开主窗口", #selector(showWindow), key: "0")
            menu.addItem(.separator())
            add("设置…", #selector(showSettings), key: ",")
            menu.addItem(.separator())
            add("退出 MicBridge", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
            NSMenu.popUpContextMenu(menu, with: event, for: sender)
        } else {
            showWindow()
        }
    }
    @objc private func showHelp() {
        if helpWindow == nil {
            let help = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            help.title = "MicBridge 使用说明"; help.isReleasedWhenClosed = false
            let text = Bundle.main.url(forResource: "MicBridge Help", withExtension: "txt").flatMap { try? String(contentsOf: $0) } ?? "请参阅项目中的 docs/MICBRIDGE.txt。"
            help.contentViewController = NSHostingController(rootView: BridgeHelpView(text: text))
            help.minSize = NSSize(width: 460, height: 360); help.center(); helpWindow = help
        }
        NSApp.setActivationPolicy(.regular); helpWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示主窗口", action: #selector(showWindow), keyEquivalent: ""); show.target = self; menu.addItem(show)
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ""); settings.target = self; menu.addItem(settings)
        return menu
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        if settingsWindow?.isVisible != true && helpWindow?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !choosingExit else { return .terminateCancel }
        // No connected SPP session means there is no remote mode to change.
        guard model.active, !model.exitPending else {
            return model.requestTermination(restoreHFP: model.exitPending)
        }
        choosingExit = true
        defer { choosingExit = false }
        let alert = NSAlert()
        alert.messageText = "退出 MicBridge"
        alert.informativeText = "仅本次退出：恢复原按键功能，保存录音并关闭连接，保留发射器重连信息。\n不再使用：退出 SPP 模式，恢复普通蓝牙麦克风。"
        alert.addButton(withTitle: "仅本次退出")
        alert.addButton(withTitle: "不再使用，恢复普通麦克风")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return model.requestTermination(restoreHFP: false)
        case .alertSecondButtonReturn: return model.requestTermination(restoreHFP: true)
        default: return .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stopModeObservation() }
    func applicationDidBecomeActive(_ notification: Notification) { model?.updateLaunchStatus() }
}

let application = NSApplication.shared
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-design" {
    do { try renderDesignSnapshots(to: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
    catch { fputs("\(error)\n", stderr); exit(1) }
}
let delegate = BridgeAppDelegate()
application.delegate = delegate
application.run()
