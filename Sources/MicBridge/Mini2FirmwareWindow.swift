import AppKit
import SwiftUI
import Mini2Protocol

final class Mini2FirmwareWindow: NSWindowController, NSWindowDelegate {
    let updater: Mini2FirmwareUpdater
    var onClose: (() -> Void)?
    private var released = false
    init(bridge: BridgeController, address: String) {
        updater = Mini2FirmwareUpdater(bridge: bridge, address: address)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mini 2 固件管理"; window.identifier = NSUserInterfaceItemIdentifier("MicBridge.Mini2Firmware")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: Mini2FirmwareView(updater: updater))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if released { return true }
        guard !updater.blocksClose else { NSSound.beep(); return false }
        updater.close { [weak self] in
            guard let self else { return }
            self.released = true; self.close(); self.onClose?()
        }
        return false
    }
}

struct Mini2FirmwareView: View {
    @ObservedObject var updater: Mini2FirmwareUpdater
    @State private var prepared = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ReferenceHeading(title: "Mini 2 固件管理", symbol: "cpu", subtitle: "安装四热键补丁，或还原官方固件")
                ReferenceCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("1 · 选择刷入内容").font(.headline)
                        HStack(spacing: 10) {
                            choice("安装进阶补丁", kind: .advanced)
                            choice("恢复官方固件", kind: .official)
                        }
                        Text(updater.kind == .advanced
                             ? "MBRG r2 · 基于官方 02.03.17.00，增加可控四热键模式。此为实验性修改，故障恢复路径尚未验证。"
                             : "官方 02.03.17.00 · 移除 MBRG 补丁，恢复原厂按键行为，四热键进阶模式将不可用。此操作需要正常 BLE 连接，不是变砖救援工具。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("选择固件文件…") { updater.chooseFile() }
                                .buttonStyle(ReferenceButtonStyle(inset: 12)).disabled(updater.stage != .select)
                            Text(updater.fileName).font(.caption).lineLimit(2).truncationMode(.middle)
                        }
                        Text("仅接受校验匹配的完整 Mini 2 固件包，不支持其他型号或任意修改文件。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ReferenceCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("2 · 准备与设备检查").font(.headline)
                        Text("• 打开发射器，电量至少 50%，保持稳定供电。\n• 关闭手机 DJI Mimo、其他接收设备和 Demo。\n• 关闭使用 DJI 原生输入的录音与系统电平页面。\n• 检查时会退出 SPP；刷入期间不要关机、退出 App 或中断蓝牙。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Toggle("已完成准备，并了解所选固件的影响", isOn: $prepared)
                            .toggleStyle(.checkbox).disabled(updater.stage != .select)
                        HStack {
                            Button("检查设备") { updater.check() }.buttonStyle(ReferenceButtonStyle(inset: 14))
                                .disabled(!prepared || !updater.canCheck)
                            Text(updater.deviceInfo).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ReferenceCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("3 · 刷入与校验").font(.headline)
                        FirmwareTransferProgress(updater: updater, transfer: updater.transfer)
                        Text(updater.status).font(.system(size: 12)).foregroundStyle(updater.stage == .failed ? Color.orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if updater.stage == .done {
                            Text(updater.kind == .advanced
                                 ? "关闭此窗口后连接 SPP，设备信息会重新识别 MBRG 能力；确认后可开启进阶模式。"
                                 : "进阶模式已关闭。关闭此窗口后可重新连接，使用原厂两热键映射。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if updater.stage == .failed {
                            Text("未自动重刷。请保留日志，关闭窗口后按提示排查，再决定是否重试。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(updater.kind == .advanced ? "开始刷入 r2" : "开始恢复官方固件") { updater.flash() }
                                .buttonStyle(ReferenceButtonStyle(prominent: true, inset: 14)).disabled(!updater.canFlash)
                            Spacer()
                            Button("查看日志") { NSWorkspace.shared.activateFileViewerSelecting([updater.log.url]) }
                                .buttonStyle(ReferenceButtonStyle(inset: 12))
                        }
                    }
                }
            }.padding(18)
        }.background(bridgeCanvas).frame(width: 600, height: 680)
            .onChange(of: updater.kind) { _ in prepared = false }
    }
    private func choice(_ title: String, kind: Mini2FirmwareImage.Kind) -> some View {
        Button { updater.chooseKind(kind) } label: {
            Text(title).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(updater.kind == kind ? Color.blue : .primary)
                .background(updater.kind == kind ? Color.blue.opacity(0.12) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(updater.stage != .select)
    }
}
private struct FirmwareTransferProgress: View {
    @ObservedObject var updater: Mini2FirmwareUpdater
    @ObservedObject var transfer: Mini2FirmwareTransfer
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(updater.stage == .rebooting ? "传输与镜像校验完成 · 等待重启" : updater.stage == .done ? "设备重启回读完成" : transfer.active ? transfer.status : "等待开始")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(transfer.progress * 100))%").font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            ProgressView(value: transfer.progress).tint(.blue)
        }
    }
}
