import AppKit
import SwiftUI
import ServiceManagement
import IOBluetooth
import MicLinkCore
import MicBridgeSupport

private let panel = Color(nsColor: .controlBackgroundColor)
let bridgeCanvas = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(red: 0.965, green: 0.965, blue: 0.975, alpha: 1)
})
private let subtle = Color(nsColor: .separatorColor)

extension Notification.Name {
    static let bridgeSettingsRequested = Notification.Name("MicBridge.settingsRequested")
    static let bridgeDisconnectRequested = Notification.Name("MicBridge.disconnectRequested")
}

private enum ArtworkCache {
    static var trimmed: [String: NSImage] = [:]
    static func visibleImage(_ url: URL) -> NSImage? {
        if let image = trimmed[url.path] { return image }
        guard let source = NSImage(contentsOf: url),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: cg.width, height: cg.height,
                  bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return sourceImage(url) }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
        for y in 0..<cg.height {
            for x in 0..<cg.width where bytes[(y * cg.width + x) * 4 + 3] > 8 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = context.makeImage()?.cropping(to: CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1)) else { return source }
        let image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        trimmed[url.path] = image
        return image
    }
    private static func sourceImage(_ url: URL) -> NSImage? { NSImage(contentsOf: url) }
}
private struct DeviceControlsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 104
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
struct ProductArtwork: View {
    let model: MicModel
    var size: CGFloat = 106
    var visibleHeight: CGFloat? = nil
    var body: some View {
        Group {
            if let name = model.imageName, let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Devices"),
               let image = visibleHeight == nil ? NSImage(contentsOf: url) : ArtworkCache.visibleImage(url) {
                if visibleHeight != nil { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(nsImage: image).resizable().scaledToFit().scaleEffect(model == .mic2 ? 1.5 : 1.22) }
            } else { Image(systemName: "mic").font(.system(size: 33, weight: .light)).foregroundStyle(.secondary) }
        }.frame(width: size, height: visibleHeight ?? size, alignment: .top).clipped().accessibilityLabel(model.title + "产品图")
    }
}
struct StudioSignal: NSViewRepresentable {
    @Environment(\.legibilityWeight) private var legibilityWeight
    let signal: SignalView
    var compact = false
    func makeNSView(context: Context) -> SignalView { signal }
    func updateNSView(_ nsView: SignalView, context: Context) { nsView.emphasizeText = legibilityWeight == .bold; nsView.compactMeter = compact }
}
struct Surface<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var fillsHeight = false
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading).padding(16)
            .background(panel).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(contrast == .increased ? Color.primary : subtle.opacity(0.55), lineWidth: 1))
    }
}

struct ReferenceCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(padding)
            .background(panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.025), lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 6, y: 2)
    }
}
/// Keep the designed label while a native menu handles keyboard and selection.
struct ReferenceMenu<Content: View, Label: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label
    var body: some View {
        Menu { content } label: {
            label.contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }
}
struct ReferenceButtonStyle: ButtonStyle {
    var prominent = false
    var inset: CGFloat = 0
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, inset).padding(.vertical, inset > 0 ? 8 : 0)
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(enabled ? 0.85 : 0.4))
            .background {
                if prominent {
                    LinearGradient(colors: [Color(red: 0.07, green: 0.57, blue: 1), Color(red: 0, green: 0.43, blue: 0.94)], startPoint: .top, endPoint: .bottom)
                } else { panel }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(prominent ? Color.clear : subtle.opacity(0.55)))
            .shadow(color: prominent ? Color.blue.opacity(enabled ? 0.22 : 0.08) : .clear, radius: 7, y: 4)
            .opacity(!enabled && prominent ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

/// Shared typography and spacing for secondary windows and panels.
struct ReferenceHeading: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.blue)
                .frame(width: 38, height: 38)
                .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 16, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct DeviceBatteryIndicator: View {
    let percent: Int
    private var tint: Color { percent <= 20 ? .red : .green }
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).stroke(tint.opacity(0.7), lineWidth: 1)
                    if percent > 0 {
                        RoundedRectangle(cornerRadius: 1).fill(tint)
                            .frame(width: max(1, 18 * CGFloat(percent) / 100), height: 7).padding(.leading, 2)
                    }
                }.frame(width: 22, height: 11)
                RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.7)).frame(width: 2, height: 5)
            }.accessibilityHidden(true)
            Text("\(percent)%").monospacedDigit().foregroundStyle(.primary)
        }.font(.system(size: 11, weight: .medium))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("剩余电量 \(percent)%")
            .help("设备最近报告的剩余电量")
    }
}

struct BridgeWindow: View {
    @ObservedObject var model: BridgeController
    @State private var confirmDisconnect = false
    @State private var showAudioTest = false
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if model.preview {
                    Text("界面预览 · 不连接设备或发送指令").font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if model.page == .settings {
                    BridgeSettingsView(model: model)
                } else if model.page == .device {
                    GeometryReader { viewport in
                        ScrollView {
                            devicePage(width: viewport.size.width, availableHeight: viewport.size.height)
                                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 8)
                        }
                    }
                    deviceFooter.padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 10)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch model.page {
                            case .device: devicePage(width: geometry.size.width)
                            case .models: modelsPage
                            case .diagnostics: diagnosticsPage
                            case .settings: settingsPage
                            }
                        }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.background(bridgeCanvas)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bridgeDisconnectRequested)) { _ in
            if model.active && !model.closing && !model.exitPending { confirmDisconnect = true }
        }
        .alert("断开 SPP？", isPresented: $confirmDisconnect) {
            Button("取消", role: .cancel) {}.keyboardShortcut(.cancelAction)
            Button("断开", role: .destructive) { model.disconnect() }
        } message: { Text("结束录音并断开 SPP。退出后建议将 Mic 2 关机再开机，再使用普通蓝牙录音。") }

    }
    private var stateColor: Color {
        if model.connectionWarning { return .orange }
        if [.streaming, .hfpRecording].contains(model.phase) { return .green }
        return model.bluetoothConnected ? .accentColor : .secondary
    }
    private var captureInProgress: Bool { model.recording || model.hfpRecording }
    private func devicePage(width: CGFloat, availableHeight: CGFloat = 0) -> some View {
        VStack(spacing: 18) {
            if width < 780 {
                deviceCard
                mappingCard
            } else {
                HStack(alignment: .top, spacing: 18) {
                    deviceCard.frame(width: min(358, max(280, (width - 62) * 0.326)))
                    mappingCard.frame(maxWidth: .infinity)
                }
                // Fill the viewport above the meter instead of leaving unused space below it.
                .frame(minHeight: max(0, availableHeight - 20 - 8 - 18 - 76))
            }
            audioStrip(compact: width < 780)
        }
    }
    private var deviceFooter: some View {
            HStack(spacing: 12) {
                Label(model.bluetoothConnected ? "蓝牙已连接" : "蓝牙未连接", systemImage: "antenna.radiowaves.left.and.right")
                    .padding(.horizontal, 10).padding(.vertical, 5).background(panel, in: Capsule())
                Text("·").foregroundStyle(.tertiary)
                Text(model.bluetoothConnected ? "发射器已连接 Mac" : "等待发射器连接").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { openDeviceSettings() } label: {
                    HStack(spacing: 6) { Text("设备高级设置"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                }.buttonStyle(.plain)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
    }
    private var mappingCard: some View {
        ReferenceCard {
            ButtonMappingPanel(shortcuts: model.buttonShortcuts,
                available: model.preview || model.selected?.model.adapter == .mic2SPP,
                connected: model.phase == .streaming, canConnect: model.canConnect,
                connect: { model.connect() }, hotkeyEnabled: model.hotkeyEnabled,
                hotkeyActive: model.keyMode.enabled == true, modeBusy: model.keyMode.busy,
                modeStatus: model.hotkeyStatus, canChangeMode: model.canChangeHotkey,
                setHotkey: { model.setHotkey($0) })
        }
    }
    private func openDeviceSettings() {
        NotificationCenter.default.post(name: .bridgeSettingsRequested, object: nil)
    }
    private var deviceCard: some View {
        ReferenceCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    ProductArtwork(model: model.model, size: 96, visibleHeight: 136)
                        .shadow(color: .black.opacity(0.12), radius: 5, y: 5)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.model.title).font(.system(size: 24, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                        HStack(spacing: 6) {
                            Circle().fill(stateColor).frame(width: 6, height: 6)
                            Text(model.bluetoothConnected ? model.connectionLabel : "未连接").font(.system(size: 11, weight: .medium))
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.primary.opacity(0.045), in: Capsule())
                        if model.bluetoothConnected, let percent = model.batteryPercent, (0...100).contains(percent) {
                            DeviceBatteryIndicator(percent: percent)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 142).padding(.bottom, 14)
                Divider().opacity(0.5)
                HStack {
                    Text("选择设备").fontWeight(.semibold)
                    Spacer()
                    Text("发现 \(model.devices.count) 台").foregroundStyle(.secondary)
                }.font(.system(size: 10)).padding(.top, 12).padding(.bottom, 9)
                HStack(spacing: 8) {
                    ReferenceMenu {
                        Button("选择发射器") { model.select("") }
                        ForEach(model.devices) { device in
                            Button { model.select(device.id) } label: {
                                if model.selectedID == device.id { Label(device.name, systemImage: "checkmark") }
                                else { Text(device.name) }
                            }
                        }
                    } label: {
                        HStack {
                            Text(model.selected?.name ?? "选择发射器").lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 38)
                            .background(panel, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(subtle.opacity(0.6)))
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .disabled(model.hfpBusy || model.active || model.captureBlocked || model.importing || model.devices.isEmpty)
                        .accessibilityLabel("发射器").help(model.name)
                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15))
                            .frame(width: 38, height: 38)
                    }.buttonStyle(ReferenceButtonStyle())
                        .disabled(model.hfpBusy || model.active || model.closing || model.refreshing || model.preview || model.captureBlocked || model.importing)
                        .accessibilityLabel("刷新列表").help("刷新已配对设备列表（⌘⇧R）")
                }
                Button {
                    if model.active { confirmDisconnect = true } else { model.connect() }
                } label: {
                    Label(model.exitPending || model.closing ? "正在退出…" : model.active ? "断开设备" : "连接设备", systemImage: "link")
                        .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 42)
                }.buttonStyle(ReferenceButtonStyle(prominent: true)).padding(.top, 12)
                    .disabled(model.active ? (model.closing || model.exitPending) : !model.canConnect)
                    .help("连接或断开 SPP（⌘K）")
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("连接后自动接收音频，并应用热键设置")
                }.font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 10)
                if model.exitConfirmed && !model.active {
                    Text(model.connectionDetail).font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
                }
                if model.phase == .streaming {
                    HStack(spacing: 8) {
                        Text("降噪模式").font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 4)
                        if model.denoise.busy { ProgressView().controlSize(.mini) }
                        if let enabled = model.denoise.enabled {
                            Toggle("降噪模式", isOn: Binding(get: { enabled }, set: { model.setDenoise($0) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .disabled(!model.canChangeDenoise)
                        } else if model.denoise.error != nil {
                            Button("重新读取") { model.readDenoise() }
                                .font(.system(size: 11)).buttonStyle(.borderless)
                                .disabled(!model.canQuery).help(model.denoise.error ?? "")
                        } else {
                            Text("读取中…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(minHeight: 28).padding(.vertical, 4)
                }
                Spacer(minLength: 0)
                Divider().opacity(0.5)
                Button { openDeviceSettings() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "ipod").frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        Text("设备详情").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("固件 \(model.firmware)").font(.system(size: 10)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }.padding(.top, 10)
                }.buttonStyle(.plain)
            }.frame(maxHeight: .infinity, alignment: .top)
        }
    }
    private func audioStrip(compact: Bool) -> some View {
        ReferenceCard(padding: 18) {
            if compact {
                VStack(spacing: 12) { audioLabel; StudioSignal(signal: model.signalView, compact: true).frame(height: 42); audioActions }
            } else {
                HStack(spacing: 20) {
                    audioLabel.frame(width: 142, alignment: .leading)
                    StudioSignal(signal: model.signalView, compact: true).frame(height: 40)
                    audioActions
                }
            }
        }
    }
    private var audioLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 16)).frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("音频检测").font(.system(size: 14, weight: .semibold))
                Text("输入电平 · 实时监测").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    private var audioActions: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle().fill(captureInProgress ? Color.red : model.phase == .streaming ? .green : .secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(captureInProgress ? model.elapsed : model.phase == .streaming ? "正在收音" : "等待音频")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                }
                Text(model.phase == .streaming ? "SPP 音频已接入" : "连接设备后自动开始检测").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Button { showAudioTest.toggle() } label: {
                Label(captureInProgress ? "录音中" : "测试音频", systemImage: captureInProgress ? "record.circle" : "speaker.wave.2")
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 16).frame(height: 38)
            }.buttonStyle(ReferenceButtonStyle()).popover(isPresented: $showAudioTest, arrowEdge: .bottom) {
                ReferenceCard { recordingControls }.padding(16).frame(width: 390).background(bridgeCanvas)
            }
        }
    }
    var recordingControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReferenceHeading(title: "测试与录音", symbol: "waveform")
            Text(model.elapsed).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
            Text(model.recordingHint).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(model.recordingButtonTitle) { model.toggleRecording() }
                .buttonStyle(ReferenceButtonStyle(prominent: true, inset: 14)).disabled(!model.canToggleRecording)
            if model.hfpTestFile != nil && !model.active {
                Button(model.playing == model.hfpTestFile ? "停止试听" : "试听测试录音") { model.playHFPTest() }.buttonStyle(ReferenceButtonStyle(inset: 12))
                    .disabled(model.hfpBusy || model.closing)
            }
            Divider()
            Button { model.revealFolder() } label: { Label("打开录音保存位置", systemImage: "folder") }
                .buttonStyle(ReferenceButtonStyle(inset: 12))
        }
    }
    private func settingText(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
    private func settingToggle(_ title: String, _ detail: String, value: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack(spacing: 20) {
            settingText(title, detail)
            Spacer(minLength: 12)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).fixedSize().disabled(disabled)
        }
    }
    var settingsPage: some View { BridgeSettingsView(model: model) }
    var modelsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReferenceHeading(title: "兼容设备", symbol: "mic.and.signal.meter", subtitle: "查看各型号的支持状态。")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 15) {
                ForEach(MicModel.allCases.filter { $0 != .unknown }) { profile in
                    ReferenceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            ProductArtwork(model: profile, size: 116, visibleHeight: 128).frame(maxWidth: .infinity)
                            Text(profile.title).font(.system(size: 14, weight: .semibold))
                            Text(profile.compatibility).font(.system(size: 11)).foregroundStyle(.secondary).frame(minHeight: 34, alignment: .topLeading)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    var diagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReferenceCard {
                VStack(alignment: .leading, spacing: 18) {
                    ReferenceHeading(title: "设备信息", symbol: "info.circle", subtitle: "复用当前 SPP 连接查询，保持音频接收。")
                    HStack(spacing: 8) { ForEach(Array(MicControlCommand.allCases.prefix(3)), id: \.rawValue) { c in Button(c.title) { model.send(c) }.buttonStyle(ReferenceButtonStyle(inset: 12)).disabled(!model.canQuery || model.preview) } }
                    HStack {
                        Button(MicControlCommand.battery.title) { model.send(.battery) }
                            .buttonStyle(ReferenceButtonStyle(inset: 12)).disabled(!model.canQuery || model.preview)
                        Text(model.controlHealth).font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.controlStatus.isEmpty {
                        Text(model.controlStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ReferenceCard {
                VStack(alignment: .leading, spacing: 10) {
                    ReferenceHeading(title: "连接状态", symbol: "link")
                    Label(model.ready ? "系统音频保护已启用" : "SPP 连接时锁定非 DJI 系统音频", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("停止录音会保留 SPP 连接。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.phase == .streaming { Text("SPP 音频：48 kHz / 单声道").font(.caption).foregroundStyle(.secondary) }
                    if let recovery = model.recoveryDescription {
                        Text(recovery).font(.caption).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let error = model.audioObservationError {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if model.preview {
                        Picker("预览状态", selection: Binding(get: { model.phase }, set: { model.previewState($0) })) {
                            ForEach(ConnectionPhase.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    Text(model.systemMicStatus).font(.caption).foregroundStyle(.secondary)
                    if !model.systemMicAvailable {
                        Button("安装音频组件…") { model.openSystemMicrophoneSetup() }.buttonStyle(ReferenceButtonStyle(inset: 12)).disabled(model.preview)
                    } else if model.systemMicEnabled && !model.systemMicIsDefault {
                        Button("设为系统输入") { model.useSystemMicrophoneAsDefault() }.buttonStyle(ReferenceButtonStyle(inset: 12))
                    }
                    if !model.systemMicMetrics.isEmpty {
                        Text(model.systemMicMetrics).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !model.exitStatus.isEmpty {
                        Text(model.exitStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(model.modeEvidenceDetail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("只读连接和系统音频属性，不主动打开麦克风；音频活动可能来自输出。").font(.caption).foregroundStyle(.secondary)
                }
            }
            ReferenceCard {
                VStack(alignment: .leading, spacing: 14) {
                    ReferenceHeading(title: "状态日志", symbol: "text.alignleft")
                    if model.stateHistory.isEmpty { Text("暂无状态变化").foregroundStyle(.secondary) }
                    ForEach(Array(model.stateHistory.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    Button("查看状态日志") { if let url = model.stateLogURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.buttonStyle(ReferenceButtonStyle(inset: 12)).disabled(model.stateLogURL == nil)
                }
            }

        }
    }
}

