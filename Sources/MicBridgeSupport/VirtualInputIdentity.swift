import CoreAudio

/// Explicit loopback identities. USB transport alone does not make our driver a speaker.
public enum VirtualInputIdentity {
    public enum Profile: Int, CaseIterable {
        case micBridge, blackHole
        public var uid: String { self == .micBridge ? "MicBridgeAudio2ch_UID" : "BlackHole2ch_UID" }
        public var name: String { self == .micBridge ? "MicBridge Audio" : "BlackHole 2ch" }
        public var manufacturer: String { self == .micBridge ? "MicBridge" : "Existential Audio Inc." }
        public var transport: UInt32 { self == .micBridge ? kAudioDeviceTransportTypeUSB : kAudioDeviceTransportTypeVirtual }
    }
    public static func profile(uid: String, name: String, manufacturer: String, transport: UInt32) -> Profile? {
        Profile.allCases.first { $0.uid == uid && $0.name == name && $0.manufacturer == manufacturer && $0.transport == transport }
    }
    public static func matches(uid: String, name: String, manufacturer: String, transport: UInt32) -> Bool {
        profile(uid: uid, name: name, manufacturer: manufacturer, transport: transport) != nil
    }
    public static func isLoopbackUID(_ uid: String) -> Bool { Profile.allCases.contains { $0.uid == uid } }
    public static func allowsRoute(uid: String, name: String, manufacturer: String, transport: UInt32, input: Bool) -> Bool {
        if isLoopbackUID(uid) {
            return input && matches(uid: uid, name: name, manufacturer: manufacturer, transport: transport)
        }
        let physical: [UInt32] = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort]
        return physical.contains(transport)
    }
}
