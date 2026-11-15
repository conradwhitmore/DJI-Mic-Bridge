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
                    ReferenceHeading(title: "设备信息", symbol: "slider.horizontal.3", subtitle: "音频设置")
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
                } else if !state.ready {
                    Text(connected ? "正在读取设备设置…" : "连接 SPP 后可调节").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
