import AppKit
import SwiftUI
import CoreBluetooth
import Mini2Protocol

final class Mini2AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let log = DemoLog()
    private lazy var ble = BLEController(log: log)
    private lazy var spp = SPPController(log: log)
    private lazy var shortcuts = Mini2ShortcutSettings(log: log)
    private var window: NSWindow!
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        spp.controlFrame = { [weak self] frame in self?.ble.observeKey(frame, transport: "SPP") }
        spp.hotkey = { [weak self] key in self?.shortcuts.receive(key) }
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Mini 2 Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""), edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MicBridge Mini 2 Demo · 0.1.6"
        window.contentMinSize = NSSize(width: 780, height: 600)
        window.contentView = NSHostingView(rootView: DemoView(ble: ble, spp: spp, ota: ble.ota, shortcuts: shortcuts, log: log))
        window.delegate = self; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log.add("Mini 2 Demo 0.1.6 就绪；未扫描、未连接、未改变音频路由")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateCancel }
        terminating = true
        // Always reply asynchronously, after applicationShouldTerminate has returned terminateLater.
        DispatchQueue.main.async { [self] in
            ble.prepareClose { [self] ok in
                guard ok else { finishTermination(false); return }
                spp.close { [self] closed in finishTermination(closed) }
            }
        }
        return .terminateLater
    }
    private func finishTermination(_ ok: Bool) {
        terminating = false; NSApp.reply(toApplicationShouldTerminate: ok)
        if !ok {
            log.add("退出尚未完成，请查看连接状态并重试关闭通道 / 退出按键测试")
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct DemoView: View {
    @ObservedObject var ble: BLEController
    @ObservedObject var spp: SPPController
    @ObservedObject var ota: StockOTAController
    @ObservedObject var shortcuts: Mini2ShortcutSettings
    @ObservedObject var log: DemoLog
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DJI Mic Mini 2").font(.title2.bold())
                        Text("02.03.17.00 · 独立协议调试").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { NSWorkspace.shared.open(log.directory) } label: { Label("打开本次日志", systemImage: "folder") }
                }
                Mini2HotkeyView(shortcuts: shortcuts).disabled(ble.otaLocked)
                DisclosureGroup("官方固件调试（当前暂停）") {
                GroupBox("官方固件同版本平刷 · 02.03.17.00") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("加载官方原包") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                                panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                                if panel.runModal() == .OK, let url = panel.url { ota.load(url) }
                            }.disabled(ble.otaLocked)
                            Button("开始官方同版本平刷") { ble.startStockOTA(sppActive: spp.active || spp.discovering) }
                                .disabled(!ota.prepared || !ble.canQuery || spp.active || spp.discovering)
                            Text("仅 TX · 不降级、不修改固件").foregroundStyle(.secondary)
                        }
                        Text(ota.status).textSelection(.enabled)
                        if ota.active || ota.progress > 0 { ProgressView(value: ota.progress) }
                        Text("先查询版本与电量、确认退出按键测试。平刷期间保持设备供电，不使用 DJI 音频输入；完成后回读版本确认设备正常启动。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                }
                GroupBox("1 · BLE 控制") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("设备", selection: $ble.selectedDevice) {
                                Text("请选择扫描到的 Mini 2").tag(Optional<UUID>.none)
                                ForEach(ble.devices) { d in
                                    Text("\(d.name) · \(d.id.uuidString.suffix(6)) · \(d.rssi) dBm").tag(Optional(d.id))
                                }
                            }.disabled(ble.canDisconnect)
                            Button(ble.scanning ? "停止扫描" : "扫描") { ble.scanning ? ble.stopScan() : ble.scan() }
                                .disabled(ble.canDisconnect)
                            Button("连接 BLE") { ble.connect() }.disabled(ble.selectedDevice == nil || ble.canDisconnect)
                            Button("断开") { ble.disconnect() }.disabled(!ble.canDisconnect)
                        }
                        HStack {
                            Picker("写入", selection: $ble.writeID) {
                                Text("选择特征").tag("")
                                ForEach(ble.characteristics.filter { !$0.value.properties.intersection([.write, .writeWithoutResponse]).isEmpty }) { c in
                                    Text(c.label).tag(c.id)
                                }
                            }
                            Picker("通知", selection: $ble.notifyID) {
                                Text("选择特征").tag("")
                                ForEach(ble.characteristics.filter { !$0.value.properties.intersection([.notify, .indicate]).isEmpty }) { c in
                                    Text(c.label).tag(c.id)
                                }
                            }
                            Button(ble.subscribed ? "已订阅" : "订阅通知") { ble.subscribe() }
                                .disabled(!ble.canChangeEndpoints || ble.notifyID.isEmpty)
                        }.disabled(!ble.canChangeEndpoints)
                        HStack(spacing: 16) {
                            Button("查询版本") { ble.query(.version) }.disabled(!ble.canQuery)
                            Text("固件 \(ble.version)").monospacedDigit()
                            Divider().frame(height: 16)
                            Button("查询电量") { ble.query(.battery) }.disabled(!ble.canQuery)
                            Text(ble.battery).monospacedDigit()
                        }
                        Text(ble.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(8)
                }
                .disabled(ble.otaLocked)
                GroupBox("2 · 工厂按键测试（本轮不使用）") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            keyCard("KEY_1 · 06", count: ble.key6, active: ble.lastKey == 6)
                            keyCard("KEY_PLAY · 07", count: ble.key7, active: ble.lastKey == 7)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 8) {
                                Button("进入测试 · 60 秒") { ble.query(.keyEnter) }.disabled(!ble.canEnter || spp.active)
                                Button("确认退出测试") { ble.requestExit() }.disabled(!ble.connected || !ble.subscribed)
                            }
                        }
                        Text(ble.keyState + (ble.secondsLeft > 0 ? " · \(ble.secondsLeft) 秒后自动请求退出" : ""))
                            .font(.callout).monospacedDigit()
                        Text("先查询版本并确认退出，再进入测试。两个按钮各短按一次；计数只来自独立报告。测试模式可能影响长按关机。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                .disabled(ble.otaLocked)
                GroupBox("3 · SPP 原始数据") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("已配对 Mini", selection: $spp.selected) {
                                Text("请选择设备").tag("")
                                ForEach(spp.devices) { Text($0.name + " · " + $0.id.suffix(5)).tag($0.id) }
                            }.disabled(spp.active || spp.discovering)
                            Button("刷新列表") { spp.refresh() }.disabled(spp.active || spp.discovering)
                            Button("查询 SDP") { spp.discover() }.disabled(spp.selected.isEmpty || spp.active || spp.discovering)
                        }
                        HStack {
                            Button("连接 SPP") { spp.open() }.disabled(!spp.canOpen)
                            Button("关闭 SPP 通道") { spp.close() }.disabled(!spp.active)
                            Button("退出 SPP · 12/65") { spp.exitSPP() }.disabled(!spp.opened || spp.probing || spp.denoiseBusy)
                            Divider().frame(height: 16)
                            Button(spp.recording ? "停止保存" : "保存 WAV 与原始流 · 60 秒") { spp.toggleCapture() }.disabled(!spp.opened)
                            if spp.recording { Image(systemName: "record.circle.fill").foregroundStyle(.red) }
                        }
                        HStack {
                            Button("验证 SPP 指令") { spp.verifyCommands() }.disabled(!spp.opened || spp.probing || spp.denoiseBusy)
                            Text(spp.commandStatus).font(.caption).textSelection(.enabled)
                        }
                        HStack {
                            Text("降噪：" + (spp.denoise.map { $0 ? "开启" : "关闭" } ?? "—"))
                            Text("电源双击降噪：" + spp.denoiseButton).foregroundStyle(.secondary)
                        }
                        Text(spp.metrics).font(.system(.callout, design: .monospaced))
                        HStack {
                            Image(systemName: "button.programmable").font(.title2)
                            Text("连接键 capture：\(spp.captureCount) 次").font(.title3.monospacedDigit())
                        }
                        Text(spp.statusMetrics).font(.system(.caption, design: .monospaced))
                        Text("普通 SPP 被动监听，无需工厂模式。连接键读取 capture 事件；电源双击通过降噪变化识别。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(spp.status).font(.callout).foregroundStyle(.secondary)
                        Text("输入锁定为非 DJI（优先 MicBridge Audio）。退出 SPP 单次发送 12/65，收到 ACK 00 后关闭通道。普通关闭只释放通道；不自动重连。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                .disabled(ble.otaLocked)
                GroupBox("事件记录") {
                    ScrollView([.vertical, .horizontal]) {
                        Text(log.lines.joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }.frame(height: 140)
                }
                if let error = log.error { Text(error).foregroundStyle(.red).font(.caption) }
            }.padding(20)
        }
        .frame(minWidth: 780, minHeight: 600)
    }
    private func keyCard(_ title: String, count: Int, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "button.programmable").font(.title2).foregroundStyle(active ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text("\(count) 次").font(.title3.monospacedDigit()).foregroundStyle(active ? Color.accentColor : .primary)
            }
        }.frame(minWidth: 155, alignment: .leading)
    }
}

let app = NSApplication.shared
let delegate = Mini2AppDelegate()
app.delegate = delegate
app.run()
