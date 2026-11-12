import AppKit
import SwiftUI
import ServiceManagement

final class BridgeSettingsSelection: ObservableObject {
    @Published var page: BridgePage = .settings
}
struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeController
    @ObservedObject var selection = BridgeSettingsSelection()
    private let pages: [(BridgePage, String, String)] = [
        (.settings, "常规", "gearshape"), (.models, "兼容设备", "mic.and.signal.meter"), (.diagnostics, "高级诊断", "terminal")
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(pages, id: \.0) { page, title, symbol in
                    Button { selection.page = page } label: {
                        Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 36)
                            .foregroundStyle(selection.page == page ? Color.blue : .secondary)
                            .background(selection.page == page ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .shadow(color: selection.page == page ? .black.opacity(0.04) : .clear, radius: 3, y: 1)
                    }.buttonStyle(.plain).accessibilityAddTraits(selection.page == page ? .isSelected : [])
                }
            }.padding(5).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)
            ScrollView {
                Group {
                    switch selection.page {
                    case .models: BridgeWindow(model: model).modelsPage
                    case .diagnostics: BridgeWindow(model: model).diagnosticsPage
                    default: generalSettings
                    }
                }.padding(.horizontal, 22).padding(.bottom, 22).frame(maxWidth: .infinity, alignment: .leading)
            }.id(selection.page)
        }.background(bridgeCanvas).frame(minWidth: 540, minHeight: 460)
    }
    private func toggleRow(_ title: String, detail: String? = nil, value: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 10)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(disabled)
        }
    }
    private var generalSettings: some View {
        VStack(spacing: 16) {
            ReferenceCard {
                VStack(alignment: .leading, spacing: 16) {
                    ReferenceHeading(title: "启动", symbol: "power")
                    toggleRow("登录时启动", detail: model.launchStatus,
                              value: Binding(get: { model.launchEnabled }, set: { model.setLaunch($0) }), disabled: model.preview)
                    if model.launchNeedsApproval {
                        Button("前往系统登录项批准") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(ReferenceButtonStyle(inset: 12))
                    }
                    Divider().opacity(0.4)
                    toggleRow("登录启动时显示主窗口", value: $model.showWindow)
                }
            }
            ReferenceCard {
                VStack(alignment: .leading, spacing: 16) {
                    ReferenceHeading(title: "连接", symbol: "link")
                    toggleRow("蓝牙连接后自动进入 SPP", detail: "退出观察期间暂停，下次进入需手动连接。", value: $model.autoSPP, disabled: model.preview || model.recovery.started != nil)
                }
            }
            ReferenceCard {
                VStack(alignment: .leading, spacing: 16) {
                    ReferenceHeading(title: "录音", symbol: "waveform")
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("保存位置").font(.system(size: 12, weight: .medium))
                            Text(model.recordingFolder.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Button("更改…") { model.chooseFolder() }.buttonStyle(ReferenceButtonStyle(inset: 12)).disabled(model.hfpBusy || model.recording || model.importing)
                    }
                    Divider().opacity(0.4)
                    HStack {
                        Text("录音时长").font(.system(size: 12, weight: .medium))
                        Spacer()
                        ReferenceMenu {
                            Button("手动 / 最长 1 小时") { model.duration = 3600 }
                            Button("30 秒") { model.duration = 30 }
                            Button("1 分钟") { model.duration = 60 }
                            Button("5 分钟") { model.duration = 300 }
                        } label: {
                            HStack {
                                Text(model.duration == 30 ? "30 秒" : model.duration == 60 ? "1 分钟" : model.duration == 300 ? "5 分钟" : "手动 / 最长 1 小时")
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.down").font(.system(size: 9))
                            }.font(.system(size: 12)).padding(.horizontal, 12).frame(width: 180, height: 36)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.055)))
                        }.accessibilityLabel("录音时长").disabled(model.hfpBusy || model.recording)
                    }
                }
            }
        }
    }
}

struct BridgeHelpView: View {
    let text: String
    var body: some View {
        ScrollView {
            ReferenceCard {
                VStack(alignment: .leading, spacing: 18) {
                    ReferenceHeading(title: "使用说明", symbol: "questionmark.circle", subtitle: "MicBridge")
                    Text(text).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(22)
        }.background(bridgeCanvas).frame(minWidth: 440, minHeight: 330)
    }
}
