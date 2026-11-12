import AppKit
import ApplicationServices
import SwiftUI
import MicLinkCore
import MicBridgeSupport

extension MicButton {
    var shortcutTitle: String {
        switch self { case .link: return "连接键"; case .power: return "电源键"; case .record: return "录音键" }
    }
}

/// Owns only shortcut preferences and dispatch; never opens Bluetooth or audio.
final class ButtonShortcuts: ObservableObject {
    @Published private(set) var settings = ButtonShortcutSettings()
    @Published private(set) var trusted = false
    @Published private(set) var lastEvent = "按下发射器按键，查看最近事件。"
    @Published private(set) var eventCounts: [MicButton: UInt64] = [:]
    var editing = false
    private var device = ""
    private var gate = ButtonShortcutGate()
    private let defaults: UserDefaults
    private let preview: Bool
    init(defaults: UserDefaults, preview: Bool) { self.defaults = defaults; self.preview = preview }
    func select(_ id: String) {
        guard id != device else { return }
        device = id; gate = ButtonShortcutGate(); lastEvent = "按下发射器按键，查看最近事件。"
        settings = defaults.data(forKey: preferenceKey).flatMap { try? JSONDecoder().decode(ButtonShortcutSettings.self, from: $0) } ?? ButtonShortcutSettings()
    }
    private var preferenceKey: String { "buttonShortcuts.v1." + device }
    private func save() {
        guard !preview, !device.isEmpty, let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: preferenceKey)
    }
    func bind(_ button: MicButton, to shortcut: ButtonShortcut?) {
        guard shortcut == nil || shortcut?.isValid == true else { return }
        settings.bindings[button.rawValue] = shortcut; save()
    }
    func refreshPermission() { if !preview { trusted = AXIsProcessTrusted() } }
    func requestPermission() {
        guard !preview else { return }
        trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func beginSession() { gate = ButtonShortcutGate() }
    func receive(_ event: MicKeyTestEvent, active: Bool) {
        let time = Date().timeIntervalSince1970
        guard !preview, active, gate.accept(button: event.button.rawValue, sequence: event.sequence, time: time) else { return }
        eventCounts[event.button, default: 0] &+= 1
        let name = event.button.shortcutTitle + "短按"
        lastEvent = "最近：" + name
        guard !editing, let shortcut = settings.bindings[event.button.rawValue], shortcut.isValid else { return }
        refreshPermission()
        guard trusted else { lastEvent = name + " · 需要辅助功能授权"; return }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return }
        if shortcut.keyCode == 63 {
            down.type = .flagsChanged; up.type = .flagsChanged
            down.flags = .maskSecondaryFn; up.flags = []
        } else {
            down.flags = CGEventFlags(rawValue: shortcut.modifiers); up.flags = down.flags
        }
        // Paired in the same turn: no held key survives a disconnect or app quit.
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        lastEvent = name + " → " + shortcut.title
    }
}

struct ButtonShortcutSettingsView: View {
    @ObservedObject var shortcuts: ButtonShortcuts
    let available: Bool
    @State private var editingButton: MicButton?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("按键快捷键", systemImage: "keyboard").font(.headline)
            ForEach([MicButton.link, .power, .record], id: \.rawValue) { button in
                HStack {
                    Text(button.shortcutTitle).font(.callout)
                    Spacer()
                    Menu {
                        Button("不设置") { shortcuts.bind(button, to: nil) }
                        Button("回车 ↩") { shortcuts.bind(button, to: .returnKey) }
                        Button("Fn / 🌐") { shortcuts.bind(button, to: .functionKey) }
                        Divider()
                        Button("自定义快捷键…") { shortcuts.editing = true; editingButton = button }
                    } label: {
                        Text(shortcuts.settings.bindings[button.rawValue]?.title ?? "不设置")
                            .frame(width: 104, alignment: .trailing)
                    }.menuStyle(.borderlessButton).fixedSize().disabled(!available)
                        .accessibilityLabel(button.shortcutTitle + "快捷键")
                }
            }
            if available && !shortcuts.settings.bindings.isEmpty && !shortcuts.trusted {
                Button("授权辅助功能…") { shortcuts.requestPermission() }
                Text("允许 MicBridge 向当前 App 发送快捷键。").font(.caption).foregroundStyle(.secondary)
            }
            if let button = editingButton {
                Divider()
                ShortcutEditor(button: button, initial: shortcuts.settings.bindings[button.rawValue]) { value in
                    shortcuts.bind(button, to: value); editingButton = nil; shortcuts.editing = false
                } cancel: { editingButton = nil; shortcuts.editing = false }
                .id(button.rawValue)
            }
        }
        .onDisappear { shortcuts.editing = false }
    }
}

struct ButtonMappingPanel: View {
    @ObservedObject var shortcuts: ButtonShortcuts
    let available: Bool
    let connected: Bool
    let canConnect: Bool
    let connect: () -> Void
    let hotkeyEnabled: Bool
    let hotkeyActive: Bool
    let modeBusy: Bool
    let modeStatus: String
    let canChangeMode: Bool
    let setHotkey: (Bool) -> Void
    @State private var editingButton: MicButton?
    private func symbol(_ button: MicButton) -> String {
        switch button { case .link: return "link"; case .power: return "power"; case .record: return "record.circle" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mic").font(.system(size: 19)).foregroundStyle(.blue)
                    .frame(width: 40, height: 40).background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 7) {
                    Text("麦克风按键映射").font(.system(size: 19, weight: .bold))
                    Text("启用后，短按仅触发快捷键，不再执行连接、降噪或录音操作").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if modeBusy { ProgressView().controlSize(.mini) }
                    Text("启用映射").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Toggle("启用映射", isOn: Binding(get: { hotkeyEnabled }, set: setHotkey))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!canChangeMode)
                        .help("启用后短按仅触发快捷键，关闭后恢复原按键功能")
                }.fixedSize().padding(.top, 2)
            }.padding(.bottom, 20)
            HStack {
                Text("麦克风按键")
                Spacer()
                Text("键盘快捷键").frame(width: 166, alignment: .leading)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 10)
            Divider().opacity(0.35)
            ForEach([MicButton.link, .power, .record], id: \.rawValue) { button in
                mappingRow(button).frame(minHeight: 66)
                Divider().opacity(0.3)
            }
            Spacer(minLength: 14)
            if available && !shortcuts.settings.bindings.isEmpty && !shortcuts.trusted {
                statusNote("需要辅助功能授权才能发送快捷键", action: "前往授权", enabled: true) { shortcuts.requestPermission() }
            } else if !connected {
                statusNote("设备未连接，以上映射将在连接后生效", action: "先连接设备", enabled: canConnect, perform: connect)
            } else if !hotkeyActive {
                statusNote(modeStatus, action: "", enabled: false) {}
            } else {
                statusNote(shortcuts.lastEvent, action: "", enabled: false) {}
            }
        }.frame(minHeight: 360, maxHeight: .infinity, alignment: .top)
            .sheet(isPresented: Binding(get: { editingButton != nil }, set: { if !$0 { editingButton = nil; shortcuts.editing = false } })) {
                if let button = editingButton {
                ShortcutEditor(button: button, initial: shortcuts.settings.bindings[button.rawValue]) { value in
                    shortcuts.bind(button, to: value); editingButton = nil; shortcuts.editing = false
                } cancel: { editingButton = nil; shortcuts.editing = false }
                .padding(18).frame(width: 420).background(bridgeCanvas)
                }
            }
            .onDisappear { shortcuts.editing = false }
    }
    private func statusNote(_ text: String, action: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.blue)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 6)
            if !action.isEmpty {
                Button(action, action: perform).font(.system(size: 10, weight: .semibold)).buttonStyle(.plain)
                    .foregroundStyle(.blue).disabled(!enabled)
            }
        }.padding(.horizontal, 12).frame(minHeight: 40)
            .background(Color.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.09)))
    }
    private func mappingRow(_ button: MicButton) -> some View {
        let value = shortcuts.settings.bindings[button.rawValue]
        let unset = value == nil
        return GeometryReader { geometry in
        HStack(spacing: 12) {
            HStack(spacing: 12) {
            ButtonEventFeedback(symbol: symbol(button), trigger: shortcuts.eventCounts[button, default: 0], tile: true)
            Text(button.shortcutTitle).font(.system(size: 14, weight: .semibold))
            }.frame(width: min(172, geometry.size.width * 0.36), alignment: .leading)
            ButtonEventFeedback(symbol: "arrow.right", trigger: shortcuts.eventCounts[button, default: 0])
                .frame(maxWidth: .infinity, alignment: .center)
            ReferenceMenu {
                Button("不设置") { shortcuts.bind(button, to: nil) }
                Button("回车 ↩") { shortcuts.bind(button, to: .returnKey) }
                Button("Fn / 🌐") { shortcuts.bind(button, to: .functionKey) }
                Divider()
                Button("自定义快捷键…") { shortcuts.editing = true; editingButton = button }
            } label: {
                HStack(spacing: 8) {
                    if let value {
                        Text(value.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 24)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        Text(value == .returnKey ? "回车" : value == .functionKey ? "功能键" : "自定义")
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                        Text("未设置快捷键").font(.system(size: 11, weight: .medium))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).frame(width: 166, height: 40)
                    .foregroundStyle(unset ? Color(red: 0.63, green: 0.45, blue: 0.12) : .primary)
                    .background(unset ? Color.orange.opacity(0.045) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(unset ? Color.orange.opacity(0.3) : Color.primary.opacity(0.055), style: StrokeStyle(lineWidth: 1, dash: unset ? [2, 2] : [])))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(!available)
                .accessibilityLabel(button.shortcutTitle + "快捷键")
        }.frame(height: geometry.size.height)
        }
    }
}

/// Shows reception independently of shortcut binding or Accessibility permission.
private struct ButtonEventFeedback: View {
    let symbol: String
    let trigger: UInt64
    var tile = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false
    @State private var generation = 0
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: tile ? 16 : 13, weight: .medium))
            .foregroundStyle(lit ? Color.blue : Color.secondary.opacity(tile ? 1 : 0.5))
            .offset(x: lit && !tile && !reduceMotion ? 2 : 0)
            .frame(width: tile ? 36 : nil, height: tile ? 36 : nil)
            .padding(tile ? 0 : 8)
            .background(tile ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            .onChange(of: trigger) { _ in
                guard NSApp.windows.contains(where: { $0.identifier?.rawValue == "MicBridge.MainWindow" && $0.isVisible && !$0.isMiniaturized }) else { return }
                generation += 1
                let current = generation
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.12)) { lit = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard generation == current else { return }
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.25)) { lit = false }
                }
            }
            .onDisappear { generation += 1; lit = false }
    }
}

struct ShortcutEditor: View {
    let button: MicButton
    @State var value: ButtonShortcut?
    let save: (ButtonShortcut?) -> Void
    let cancel: () -> Void
    init(button: MicButton, initial: ButtonShortcut?, save: @escaping (ButtonShortcut?) -> Void, cancel: @escaping () -> Void) {
        self.button = button; _value = State(initialValue: initial); self.save = save; self.cancel = cancel
    }
    var body: some View {
        ReferenceCard {
        VStack(alignment: .leading, spacing: 16) {
            ReferenceHeading(title: button.shortcutTitle + "快捷键", symbol: "keyboard", subtitle: "设置这个按键触发的 Mac 快捷键")
            ShortcutRecorder(value: $value).frame(maxWidth: .infinity).frame(height: 40)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            Text("点击后按下组合键；Esc 取消录入，Tab 离开。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Fn") { value = .functionKey }
                Button("回车") { value = .returnKey }
                Button("Tab") { value = ButtonShortcut(keyCode: 48, keyLabel: "⇥") }
                Button("Esc") { value = ButtonShortcut(keyCode: 53, keyLabel: "⎋") }
            }
            .buttonStyle(ReferenceButtonStyle(inset: 12))
            if value?.keyCode == 63 {
                Text("Fn / 🌐 的系统动作取决于 macOS 设置；部分系统动作不接受模拟按键。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("取消", action: cancel).buttonStyle(ReferenceButtonStyle(inset: 16)).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save(value) }.buttonStyle(ReferenceButtonStyle(prominent: true, inset: 16)).keyboardShortcut(.defaultAction).disabled(value?.isValid != true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: ButtonShortcut?
    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton(); view.isBordered = false; view.font = .systemFont(ofSize: 14, weight: .medium)
        view.setAccessibilityLabel("录入自定义快捷键")
        return view
    }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.changed = { value = $0 }; view.shortcut = value
        if !view.recording { view.title = value?.title ?? "点击录入快捷键" }
    }
}

private final class RecorderButton: NSButton {
    var shortcut: ButtonShortcut?
    var changed: ((ButtonShortcut) -> Void)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    private func begin() { window?.makeFirstResponder(self); recording = true; title = "请按快捷键…" }
    override func mouseDown(with event: NSEvent) { begin() }
    override func accessibilityPerformPress() -> Bool { begin(); return true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else {
            if event.keyCode == 49 || event.keyCode == 36 { begin() } else { super.keyDown(with: event) }
            return
        }
        if event.keyCode == 53 { finish(); return }
        if event.keyCode == 48 { finish(); window?.selectNextKeyView(self); return }
        guard !event.isARepeat else { return }
        let labels: [UInt16: String] = [36: "↩", 49: "空格", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 76: "⌤"]
        let functionCodes: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        let label = labels[event.keyCode] ?? functionCodes.firstIndex(of: event.keyCode).map { "F\($0 + 1)" } ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        accept(ButtonShortcut(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue) & ButtonShortcut.modifierMask, keyLabel: label))
    }
    override func flagsChanged(with event: NSEvent) {
        if recording && event.keyCode == 63 && event.modifierFlags.contains(.function) { accept(.functionKey) }
    }
    private func accept(_ value: ButtonShortcut) { guard value.isValid else { return }; shortcut = value; finish(); changed?(value) }
    private func finish() { recording = false; title = shortcut?.title ?? "点击录入快捷键" }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
}
