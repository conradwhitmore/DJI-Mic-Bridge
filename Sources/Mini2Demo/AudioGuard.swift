import CoreAudio
import Foundation
import MicBridgeSupport
import MicLinkCore

/// Only reads device metadata and changes defaults. Never starts an audio input or meter.
final class Mini2AudioGuard {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var locked: [(AudioObjectPropertySelector, AudioObjectID, String)] = []
    private(set) var summary = ""
    private let selectors = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                             kAudioHardwarePropertyDefaultSystemOutputDevice]
    private func property(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var p = property(selector), v: UInt32 = 0, n: UInt32 = 4
        guard AudioObjectGetPropertyData(object, &p, 0, nil, &n, &v) == noErr else { throw StreamError.invalid("读取音频设备失败") }
        return v
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var p = property(selector), v: CFString = "" as CFString, n = UInt32(MemoryLayout<CFString>.size)
        let code = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(object, &p, 0, nil, &n, $0) }
        guard code == noErr else { throw StreamError.invalid("读取音频设备标识失败") }; return v as String
    }
    private func devices() throws -> [AudioObjectID] {
        var p = property(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &p, 0, nil, &size) == noErr, size > 0 else { throw StreamError.invalid("没有可用音频设备") }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        let code = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &p, 0, nil, &size, $0.baseAddress!) }
        guard code == noErr else { throw StreamError.invalid("枚举音频设备失败") }; return ids
    }
    private func allowed(_ id: AudioObjectID, input: Bool) throws -> Bool {
        guard id != 0, try integer(id, kAudioDevicePropertyDeviceIsAlive) == 1 else { return false }
        let name = try string(id, kAudioObjectPropertyName), uid = try string(id, kAudioDevicePropertyDeviceUID)
        guard !name.uppercased().contains("DJI"), !uid.uppercased().contains("DJI") else { return false }
        var p = property(kAudioDevicePropertyStreams, input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &p, 0, nil, &size) == noErr, size > 0 else { return false }
        let transport = try integer(id, kAudioDevicePropertyTransportType)
        if !input && transport == kAudioDeviceTransportTypeBluetooth { return true }
        return VirtualInputIdentity.allowsRoute(uid: uid, name: name,
            manufacturer: try string(id, kAudioObjectPropertyManufacturer), transport: transport, input: input)
    }
    func lock() throws {
        let ids = try devices()
        var planned: [(AudioObjectPropertySelector, AudioObjectID, String)] = []
        for selector in selectors {
            let input = selector == kAudioHardwarePropertyDefaultInputDevice
            let current = try integer(system, selector)
            let candidates = try ids.filter { try allowed($0, input: input) }
            let bridge = input ? candidates.first { (try? string($0, kAudioDevicePropertyDeviceUID)) == "MicBridgeAudio2ch_UID" } : nil
            guard let chosen = bridge ?? (candidates.contains(current) ? current : candidates.first) else {
                throw StreamError.invalid("SPP 需要可用的非 DJI \(input ? "输入" : "输出")")
            }
            planned.append((selector, chosen, try string(chosen, kAudioDevicePropertyDeviceUID)))
        }
        locked = planned; try enforce()
        summary = "输入：\(try string(planned[0].1, kAudioObjectPropertyName)) · 输出：\(try string(planned[1].1, kAudioObjectPropertyName))"
    }
    func enforce() throws {
        for (selector, id, uid) in locked {
            guard try string(id, kAudioDevicePropertyDeviceUID) == uid,
                  try allowed(id, input: selector == kAudioHardwarePropertyDefaultInputDevice) else {
                throw StreamError.invalid("锁定的非 DJI 音频设备已不可用")
            }
            if try integer(system, selector) != id {
                var p = property(selector), value = id
                guard AudioObjectSetPropertyData(system, &p, 0, nil, 4, &value) == noErr,
                      try integer(system, selector) == id else { throw StreamError.invalid("音频默认路由锁定失败") }
            }
        }
    }
    func djiAudioActive() throws -> Bool {
        for id in try devices() where try string(id, kAudioObjectPropertyName).uppercased().contains("DJI") {
            if try integer(id, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 { return true }
        }
        return false
    }
}
