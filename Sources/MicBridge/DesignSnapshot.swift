import AppKit
import SwiftUI
import MicBridgeSupport

/// Own-view rendering only; no screen capture, Bluetooth, audio I/O, or login registration.
func renderDesignSnapshots(to directory: URL) throws {
    NSApp.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = BridgeController(preview: true)
    func save<V: View>(_ root: V, name: String, width: CGFloat, height: CGFloat, dark: Bool = false) throws {
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view; window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "MicBridge.Snapshot", code: 1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "MicBridge.Snapshot", code: 2) }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
    for dark in [false, true] {
        let tone = dark ? "dark" : "light"
        for page in [BridgePage.settings, .models, .diagnostics] {
            let selection = BridgeSettingsSelection(); selection.page = page
            try save(BridgeSettingsView(model: model, selection: selection), name: "subpage-\(page)-\(tone)", width: 580, height: 620, dark: dark)
        }
        try save(ShortcutEditor(button: .link, initial: .returnKey, save: { _ in }, cancel: {}).padding(18).background(bridgeCanvas), name: "shortcut-\(tone)", width: 420, height: 310, dark: dark)
        try save(ReferenceCard { BridgeWindow(model: model).recordingControls }.padding(16).background(bridgeCanvas), name: "recording-\(tone)", width: 390, height: 320, dark: dark)
    }
    try save(BridgeWindow(model: model), name: "reference-light", width: 925, height: 642)
    for dark in [false, true] {
        for page in BridgePage.allCases {
            model.page = page
            try save(BridgeWindow(model: model), name: "\(page)-\(dark ? "dark" : "light")", width: 900, height: 700, dark: dark)
        }
        model.page = .device
        model.previewState(.hfpAvailable)
        try save(BridgeWindow(model: model), name: "compact-\(dark ? "dark" : "light")", width: 530, height: 840, dark: dark)
    }
    model.page = .device
    model.bluetoothConnected = true
    model.batteryPercent = nil
    try save(BridgeWindow(model: model), name: "battery-unavailable", width: 925, height: 642)
    for level in [85, 15, 0] {
        model.batteryPercent = level
        try save(BridgeWindow(model: model), name: "battery-\(level)", width: 925, height: 642)
    }
    model.bluetoothConnected = false
    try save(BridgeWindow(model: model), name: "battery-disconnected", width: 925, height: 642)
    model.batteryPercent = nil
    for width: CGFloat in [420, 680, 760] {
        try save(BridgeWindow(model: model), name: "width-\(Int(width))", width: width, height: 900)
    }
    for phase in [ConnectionPhase.disconnected, .hfpAvailable, .hfpReady, .hfpVoiceActive, .sppConnected, .streaming, .closing, .closeUnconfirmed, .recovering, .repeatedDisconnects] {
        model.previewState(phase)
        try save(BridgeWindow(model: model), name: "state-" + phase.rawValue, width: 900, height: 720)
    }
    model.page = .device
    model.previewState(.streaming)
    model.systemMicAvailable = true
    model.systemMicEnabled = true
    model.systemMicStatus = "已启用 · 在其他软件中选择 MicBridge Audio。"
    for dark in [false, true] {
        try save(BridgeWindow(model: model), name: "system-mic-\(dark ? "dark" : "light")", width: 900, height: 720, dark: dark)
        try save(BridgeWindow(model: model), name: "system-mic-compact-\(dark ? "dark" : "light")", width: 530, height: 840, dark: dark)
    }
    model.systemMicEnabled = false; model.systemMicAvailable = false
    model.previewState(.hfpAvailable)
}
