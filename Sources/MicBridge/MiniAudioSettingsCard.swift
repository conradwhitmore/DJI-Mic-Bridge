import SwiftUI
import MicBridgeSupport
import Mini2Protocol

struct MiniAudioSettingsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: MicModel
    let state: MiniAudioSettings.ViewState
    let connected: Bool
    let editable: Bool
    let setNoise: (MiniNoiseMode) -> Void
    let setTone: (MiniVoiceTone) -> Void
    let advancedStatus: String
    let openFirmware: () -> Void
    @State var advancedExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func miniAudioChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                .frame(maxWidth: .infinity).frame(height: 34)
                .foregroundStyle(selected ? Color.blue : Color.primary)
                .background(selected ? Color.blue.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!editable)
    }
    var body: some View {
        ReferenceCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ReferenceHeading(title: "设备信息", symbol: "slider.horizontal.3")
                    Spacer()
                    if state.busy { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 14) {
                    Text("降噪模式").font(.system(size: 12, weight: .medium)).frame(width: 70, alignment: .leading)
                    HStack(spacing: 3) {
                        ForEach(MiniNoiseMode.allCases, id: \.self) { mode in
                            miniAudioChoice(mode.title, selected: state.noiseMode == mode) { setNoise(mode) }
                        }
                    }.padding(3).background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055), in: RoundedRectangle(cornerRadius: 11))
                }
                if model == .mini2 {
                    HStack(spacing: 14) {
                        Text("音色预设").font(.system(size: 12, weight: .medium)).frame(width: 70, alignment: .leading)
                        HStack(spacing: 3) {
                            ForEach(MiniVoiceTone.allCases, id: \.self) { tone in
                                miniAudioChoice(tone.title, selected: state.tone == tone) { setTone(tone) }
                            }
                        }.padding(3).background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055), in: RoundedRectangle(cornerRadius: 11))
                    }
                }
                if let error = state.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if model == .mini2 {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 14) {
                        Button {
                            withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.18)) { advancedExpanded.toggle() }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("进阶模式").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                                    if !advancedStatus.isEmpty { Text(advancedStatus).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary).rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("进阶模式")
                            .accessibilityValue(advancedExpanded ? "已展开" : "已折叠")
                        if advancedExpanded {
                            Text("需安装 MBRG r2 补丁。启用映射后，两键的单击与双击分别触发快捷键；降噪由软件调节。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("固件管理…", action: openFirmware).buttonStyle(ReferenceButtonStyle(inset: 14))
                        }
                    }
                }
            }
        }
    }
}
