import Foundation

/// Names select a candidate profile, never establish protocol compatibility by themselves.
public enum MicModel: String, CaseIterable, Identifiable {
    case mic2, mini, mini2, mic3, unknown
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mic2: return "DJI Mic 2"
        case .mini: return "DJI Mic Mini"
        case .mini2: return "DJI Mic Mini 2"
        case .mic3: return "DJI Mic 3"
        case .unknown: return "DJI Mic · 未识别型号"
        }
    }
    public var imageName: String? { self == .unknown ? nil : rawValue }
    /// Each supported model uses its own verified transport/status layout.
    public var adapter: MicAdapter? {
        switch self { case .mic2: return .mic2SPP; case .mini2: return .mini2SPP; default: return nil }
    }
    public var compatibility: String { adapter == nil ? "暂不支持连接与指令" : "支持 SPP 收音、录音与按键监听" }
    public static func identify(_ name: String) -> MicModel {
        let n = name.uppercased().filter { $0.isLetter || $0.isNumber }
        // Full suffix shape avoids matching MINI 2S, MIC 20 or future revisions as older models.
        let candidates: [(String, MicModel)] = [("DJIMICMINI2", .mini2), ("DJIMICMINI", .mini), ("DJIMIC3", .mic3), ("DJIMIC2", .mic2)]
        for (prefix, model) in candidates where n.hasPrefix(prefix) {
            let suffix = String(n.dropFirst(prefix.count))
            if suffix.isEmpty || (suffix.count == 6 && suffix.allSatisfy({ $0.isHexDigit })) { return model }
        }
        return .unknown
    }
}

public enum MicAdapter: String {
    case mic2SPP, mini2SPP
}

/// Preferences are app-scoped. Launch at login is managed separately by SMAppService.
public struct BridgePreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public var autoSPP: Bool {
        get { defaults.bool(forKey: "autoSPP") }
        nonmutating set { defaults.set(newValue, forKey: "autoSPP") }
    }
    public var resident: Bool {
        get { defaults.object(forKey: "resident") == nil || defaults.bool(forKey: "resident") }
        nonmutating set { defaults.set(newValue, forKey: "resident") }
    }
    public var showWindow: Bool {
        get { defaults.bool(forKey: "showWindowOnLaunch") }
        nonmutating set { defaults.set(newValue, forKey: "showWindowOnLaunch") }
    }
    public func prepareReconnectDeletion() { autoSPP = false }
    /// Records the user's completed restore-to-ordinary-audio workflow, not a
    /// claim that CoreAudio endpoint enumeration proves working HFP audio.
    public func ordinaryAudioRestored(for address: String) -> Bool {
        guard !address.isEmpty else { return false }
        return defaults.bool(forKey: ordinaryAudioKey(address))
    }
    public func setOrdinaryAudioRestored(_ restored: Bool, for address: String) {
        guard !address.isEmpty else { return }
        defaults.set(restored, forKey: ordinaryAudioKey(address))
    }
    private func ordinaryAudioKey(_ address: String) -> String {
        "ordinaryAudioRestored." + address.uppercased().filter { $0 != ":" && $0 != "-" }
    }
}
