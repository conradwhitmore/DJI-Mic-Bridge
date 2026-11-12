import Foundation

/// These are host-side observations, never an assertion about the TX firmware mode.
public enum BluetoothModeEvent: String {
    case hfpCreated, voiceConnected, voiceDisconnected, aclConnected, aclDisconnected

    public static func parse(_ message: String, target: String) -> Self? {
        let normalized = target.uppercased().filter { $0 != ":" && $0 != "-" }
        guard normalized.count == 12, normalized.allSatisfy({ $0.isHexDigit }) else { return nil }
        let pattern = "(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let addresses = Set(regex.matches(in: message, range: NSRange(message.startIndex..., in: message)).compactMap {
            Range($0.range, in: message).map { String(message[$0]).uppercased().filter { $0 != ":" && $0 != "-" } }
        })
        // Redacted, unaddressed and ambiguously attributed events cannot establish a mode.
        guard addresses == [normalized] else { return nil }
        if message.hasPrefix("Creating HFPAudioDevice for device ") { return .hfpCreated }
        if message.hasPrefix("Received voice audio connected event for device ") { return .voiceConnected }
        if message.hasPrefix("Received voice disconnection event for device ") { return .voiceDisconnected }
        if message.hasPrefix("ACL disconnected:") { return .aclDisconnected }
        if message.hasPrefix("ACL connected:"), message.hasSuffix(", result 0") { return .aclConnected }
        return nil
    }
}

public struct BluetoothModeEvidence {
    public private(set) var hfpCreated = false
    public private(set) var voiceConnected = false
    public private(set) var lastEvent: BluetoothModeEvent?
    public private(set) var lastEventAt: Date?
    public private(set) var beganAt: Date
    public init(since: Date = Date()) { beganAt = since }
    public mutating func reset(since: Date) { self = Self(since: since) }
    @discardableResult public mutating func accept(_ event: BluetoothModeEvent, at date: Date, now: Date) -> Bool {
        guard date >= beganAt, date >= (lastEventAt ?? beganAt), now.timeIntervalSince(date) <= 10,
              date.timeIntervalSince(now) <= 2 else { return false }
        switch event {
        case .aclConnected, .aclDisconnected: hfpCreated = false; voiceConnected = false
        case .hfpCreated: hfpCreated = true
        case .voiceConnected: hfpCreated = true; voiceConnected = true
        case .voiceDisconnected: voiceConnected = false
        }
        lastEvent = event; lastEventAt = date
        return true
    }
    /// Once system audio becomes idle, a past voice-connected event is not proof of a new session.
    /// Allow the CoreAudio activity property a brief interval to catch up to the connection event.
    public mutating func reconcile(inputAvailable: Bool, audioActive: Bool, now: Date) {
        if voiceConnected, (!inputAvailable || !audioActive),
           now.timeIntervalSince(lastEventAt ?? beganAt) > 3 { voiceConnected = false }
    }
    /// UID suffix is an observed macOS HFP endpoint convention, not a public profile API.
    public static func isHFPEndpoint(uid: String, target: String) -> Bool {
        let normalize: (String) -> String = { $0.uppercased().filter { $0 != ":" && $0 != "-" } }
        let address = normalize(target)
        return address.count == 12 && address.allSatisfy { $0.isHexDigit } && normalize(uid) == address + "TSCO"
    }
}
