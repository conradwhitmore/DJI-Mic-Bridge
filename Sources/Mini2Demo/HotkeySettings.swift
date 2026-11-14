import AppKit
import ApplicationServices
import SwiftUI
import Mini2Protocol
import MicBridgeSupport

final class Mini2ShortcutSettings: ObservableObject {
    @Published private(set) var settings = ButtonShortcutSettings()
    @Published private(set) var counts: [Mini2Hotkey: Int] = [:]
    @Published private(set) var flashes: Set<Mini2Hotkey> = []
    @Published private(set) var trusted = false
    @Published private(set) var lastEvent = "等待 SPP 按键操作"
    var editing = false
    private let log: DemoLog
    private let key = "mini2.spp.shortcutBindings.v1"
    init(log: DemoLog) {
        self.log = log
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(ButtonShortcutSettings.self, from: data) { settings = saved }
        trusted = AXIsProcessTrusted()
    }
    func bind(_ event: Mini2Hotkey, _ shortcut: ButtonShortcut?) {
        guard shortcut == nil || shortcut?.isValid == true else { return }
        settings.bindings[event.rawValue] = shortcut
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }
    func permission() {
        trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func receive(_ event: Mini2Hotkey) {
        counts[event, default: 0] += 1; let count = counts[event]!
        flashes.insert(event); lastEvent = event.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.counts[event] == count { self?.flashes.remove(event) }
        }
        guard !editing, let shortcut = settings.bindings[event.rawValue], shortcut.isValid else { return }
        trusted = AXIsProcessTrusted()
        guard trusted else { lastEvent += " · 需要辅助功能授权"; return }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return }
        if shortcut.keyCode == 63 {
            down.type = .flagsChanged; up.type = .flagsChanged; down.flags = .maskSecondaryFn; up.flags = []
        } else { down.flags = CGEventFlags(rawValue: shortcut.modifiers); up.flags = down.flags }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        lastEvent += " → " + shortcut.title; log.add("快捷键已发送：\(lastEvent)")
    }
}

struct Mini2HotkeyView: View {
    @ObservedObject var shortcuts: Mini2ShortcutSettings
    var body: some View {
        GroupBox("SPP 双热键") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Mini2Hotkey.allCases, id: \.rawValue) { key in
                    HStack(spacing: 12) {
                        Image(systemName: key == .connection ? "link" : "power")
                            .font(.title2).frame(width: 28)
                            .foregroundStyle(shortcuts.flashes.contains(key) ? Color.blue : .secondary)
                        Text(key.title).frame(width: 100, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(shortcuts.flashes.contains(key) ? Color.blue : .secondary)
                        Mini2ShortcutRecorder(value: Binding(get: { shortcuts.settings.bindings[key.rawValue] }, set: { shortcuts.bind(key, $0) }), editing: { shortcuts.editing = $0 })
                            .frame(width: 170, height: 28)
                        Menu("常用键") {
                            Button("Fn") { shortcuts.bind(key, .functionKey) }
                            Button("回车") { shortcuts.bind(key, .returnKey) }
                            Button("空格") { shortcuts.bind(key, .init(keyCode: 49, keyLabel: "空格")) }
                            Button("F13") { shortcuts.bind(key, .init(keyCode: 105, keyLabel: "F13")) }
                            Button("F14") { shortcuts.bind(key, .init(keyCode: 107, keyLabel: "F14")) }
                            Button("不发送") { shortcuts.bind(key, nil) }
                        }.frame(width: 90)
                        Spacer()
                        Text("\(shortcuts.counts[key, default: 0]) 次").monospacedDigit()
                    }
                }
                HStack {
                    Text(shortcuts.lastEvent).foregroundStyle(.secondary)
                    Spacer()
                    if !shortcuts.trusted { Button("授权发送快捷键") { shortcuts.permission() } }
                }
                Text("电源双击会切换降噪并触发热键。首次连接与断流恢复只同步状态。点击录入可设置组合键，Esc 取消，Tab 离开。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}

private struct Mini2ShortcutRecorder: NSViewRepresentable {
    @Binding var value: ButtonShortcut?
    let editing: (Bool) -> Void
    func makeNSView(context: Context) -> Mini2RecorderButton {
        let view = Mini2RecorderButton(); view.bezelStyle = .rounded
        view.setAccessibilityLabel("录入快捷键"); return view
    }
    func updateNSView(_ view: Mini2RecorderButton, context: Context) {
        view.changed = { value = $0 }; view.editing = editing; view.shortcut = value
        if !view.recording { view.title = value?.title ?? "点击录入快捷键" }
    }
}

private final class Mini2RecorderButton: NSButton {
    var shortcut: ButtonShortcut?
    var changed: ((ButtonShortcut) -> Void)?
    var editing: ((Bool) -> Void)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    private func begin() { window?.makeFirstResponder(self); recording = true; editing?(true); title = "请按快捷键…" }
    override func mouseDown(with event: NSEvent) { begin() }
    override func accessibilityPerformPress() -> Bool { begin(); return true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else {
            if event.keyCode == 49 || event.keyCode == 36 { begin() } else { super.keyDown(with: event) }; return
        }
        if event.keyCode == 53 { finish(); return }
        if event.keyCode == 48 { finish(); window?.selectNextKeyView(self); return }
        guard !event.isARepeat else { return }
        let labels: [UInt16: String] = [36:"↩",49:"空格",51:"⌫",117:"⌦",123:"←",124:"→",125:"↓",126:"↑"]
        let functions: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        let label = labels[event.keyCode] ?? functions.firstIndex(of: event.keyCode).map { "F\($0 + 1)" } ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        accept(.init(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue) & ButtonShortcut.modifierMask, keyLabel: label))
    }
    override func flagsChanged(with event: NSEvent) {
        if recording && event.keyCode == 63 && event.modifierFlags.contains(.function) { accept(.functionKey) }
    }
    private func accept(_ value: ButtonShortcut) { guard value.isValid else { return }; shortcut = value; finish(); changed?(value) }
    private func finish() { recording = false; editing?(false); title = shortcut?.title ?? "点击录入快捷键" }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
}
