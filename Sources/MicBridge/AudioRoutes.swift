import Foundation
import CoreAudio
import MicLinkCore
import MicBridgeSupport

final class AudioRoutes {
    let target: String
    let system = AudioObjectID(kAudioObjectSystemObject)
    private var locked: [AudioObjectPropertySelector: AudioObjectID] = [:]
    private var lockedUIDs: [AudioObjectID: String] = [:]
    private(set) var description = ""
    private let selectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
    init(target: String) { self.target = Self.normalized(target) }
    static func normalized(_ s: String) -> String { s.uppercased().filter { $0 != ":" && $0 != "-" } }
    func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var p = property(selector), v: UInt32 = 0, size: UInt32 = 4
        let result = AudioObjectGetPropertyData(object, &p, 0, nil, &size, &v)
        guard result == noErr else { throw StreamError.invalid("不能读取音频状态：\(result)") }; return v
    }
    func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var p = property(selector), v: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(object, &p, 0, nil, &size, $0) }
        guard result == noErr else { throw StreamError.invalid("不能读取音频设备名称") }; return v as String
    }
    func devices() throws -> [AudioObjectID] {
        var p = property(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &p, 0, nil, &size) == noErr else { throw StreamError.invalid("不能枚举音频设备") }
        guard size > 0, size % 4 == 0 else { throw StreamError.invalid("音频设备列表为空或无效") }
        var values = [AudioObjectID](repeating: 0, count: Int(size)/4)
        let result = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &p, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { throw StreamError.invalid("不能枚举音频设备") }; return values
    }
    func isTarget(_ device: AudioObjectID) throws -> Bool {
        Self.normalized(try string(device, kAudioDevicePropertyDeviceUID)).contains(target)
    }
    func isDJI(_ device: AudioObjectID) throws -> Bool {
        try isTarget(device) || string(device, kAudioObjectPropertyName).uppercased().contains("DJI")
    }
    func hasStream(_ id: AudioObjectID, input: Bool) -> Bool {
        var p = property(kAudioDevicePropertyStreams, scope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &p, 0, nil, &size) == noErr && size > 0
    }
    func isBridgeInput(_ id: AudioDeviceID) throws -> Bool {
        guard hasStream(id, input: true),
              try integer(id, kAudioDevicePropertyDeviceIsAlive) == 1 else { return false }
        return try VirtualInputIdentity.matches(uid: string(id, kAudioDevicePropertyDeviceUID),
            name: string(id, kAudioObjectPropertyName), manufacturer: string(id, kAudioObjectPropertyManufacturer),
            transport: integer(id, kAudioDevicePropertyTransportType))
    }
    private func isSafeAlternative(_ id: AudioObjectID, input: Bool) throws -> Bool {
        guard id != kAudioObjectUnknown, try !isDJI(id), hasStream(id, input: input),
              try integer(id, kAudioDevicePropertyDeviceIsAlive) == 1 else { return false }
        // The MicBridge loopback reports USB for app compatibility but must never
        // become the physical output/alert fallback.
        return try VirtualInputIdentity.allowsRoute(uid: string(id, kAudioDevicePropertyDeviceUID),
            name: string(id, kAudioObjectPropertyName), manufacturer: string(id, kAudioObjectPropertyManufacturer),
            transport: integer(id, kAudioDevicePropertyTransportType), input: input)
    }
    private func preferredInput(_ all: [AudioObjectID], current: AudioObjectID?, locked: AudioObjectID? = nil) throws -> AudioObjectID {
        let candidates = all.compactMap { id -> SPPInputSelection.Candidate? in
            guard (try? isSafeAlternative(id, input: true)) == true else { return nil }
            let bridge = try? VirtualInputIdentity.profile(uid: string(id, kAudioDevicePropertyDeviceUID),
                name: string(id, kAudioObjectPropertyName), manufacturer: string(id, kAudioObjectPropertyManufacturer),
                transport: integer(id, kAudioDevicePropertyTransportType))
            return .init(id: id, bridge: bridge,
                builtIn: (try? integer(id, kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeBuiltIn)
        }
        guard let selected = SPPInputSelection.choose(candidates, current: current, locked: locked) else {
            throw StreamError.invalid("没有可用的非 DJI 输入设备")
        }
        return selected
    }
    func lock() throws {
        let all = try devices()
        for device in all where try isTarget(device) {
            guard try integer(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 else {
                throw StreamError.invalid("Mic 2 正被系统音频使用。请退出录音软件和声音输入电平页，再试。")
            }
        }
        for selector in selectors {
            let current = try integer(system, selector)
            let input = selector == kAudioHardwarePropertyDefaultInputDevice
            let chosen: AudioObjectID
            if input { chosen = try preferredInput(all, current: current) }
            else if try isSafeAlternative(current, input: false) { chosen = current }
            else {
                let candidates = try all.filter { try isSafeAlternative($0, input: input) }
                let candidate = candidates.first(where: { (try? integer($0, kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeBuiltIn }) ?? candidates.first
                guard let candidate else { throw StreamError.invalid("需要一个可用的非 DJI 实体\(input ? "输入" : "输出")设备（内建、USB 等）") }
                chosen = candidate
            }
            lockedUIDs[chosen] = try string(chosen, kAudioDevicePropertyDeviceUID)
            locked[selector] = chosen
        }
        try check(requirePresent: true)
        description = "系统输入：\(try string(locked[selectors[0]]!, kAudioObjectPropertyName)) · 输出：\(try string(locked[selectors[1]]!, kAudioObjectPropertyName))"
    }
    func check(requirePresent: Bool, allowTargetAudio: Bool = false, allowDefaultInput: Bool = false) throws {
        // Record the unsafe condition, but still restore every available default.
        // Activity detection must not bypass the recovery path.
        var observationError: Error?
        do {
            let all = try devices()
            var present = false
            for device in all where try isTarget(device) {
                present = true
                if try integer(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 && !allowTargetAudio {
                    observationError = StreamError.invalid("检测到 Mic 2 系统音频活动，已停止 SPP")
                }
            }
            if requirePresent && !present { observationError = StreamError.invalid("Mic 2 音频设备已离线") }
        } catch { observationError = error }
        do { try restoreLockedDefaults(allowDefaultInput: allowDefaultInput) } catch {
            if let observationError {
                throw StreamError.invalid("\(observationError.localizedDescription)；\(error.localizedDescription)")
            }
            throw error
        }
        if let observationError { throw observationError }
    }
    func restoreLockedDefaults(allowDefaultInput: Bool = false) throws {
        // Keep the preferred bridge as the actual lock target, including after
        // Bluetooth reconnects. Re-evaluate driver availability without opening
        // any hardware input; output/alert protection remains independent.
        var inputSelectionError: Error?
        if !allowDefaultInput {
            do {
                let input = kAudioHardwarePropertyDefaultInputDevice
                let chosen = try preferredInput(devices(), current: try? integer(system, input), locked: locked[input])
                lockedUIDs[chosen] = try string(chosen, kAudioDevicePropertyDeviceUID)
                locked[input] = chosen
            } catch { inputSelectionError = error }
        }
        let enforced = selectors.filter { !allowDefaultInput || $0 != kAudioHardwarePropertyDefaultInputDevice }
        let failures = LockedRouteRestorer.restore(selectors: enforced, locked: locked,
            isAlive: { expected in
                guard let uid = self.lockedUIDs[expected],
                      try self.string(expected, kAudioDevicePropertyDeviceUID) == uid else {
                    throw StreamError.invalid("原非 DJI 音频设备的身份已改变")
                }
                for selector in self.selectors where self.locked[selector] == expected {
                    guard try self.isSafeAlternative(expected, input: selector == kAudioHardwarePropertyDefaultInputDevice) else {
                        throw StreamError.invalid("原非 DJI 音频设备已不可用或不再是安全的实体路由")
                    }
                }
                return true
            }, readDefault: { try self.integer(self.system, $0) },
            writeDefault: { selector, expected in
                var p = self.property(selector), value = expected
                guard AudioObjectSetPropertyData(self.system, &p, 0, nil, 4, &value) == noErr else {
                    throw StreamError.invalid("无法保持非 DJI 音频路由")
                }
            })
        var messages = failures.map(\.message)
        if let inputSelectionError { messages.append(inputSelectionError.localizedDescription) }
        if !messages.isEmpty { throw StreamError.invalid(messages.joined(separator: "；")) }
    }
    static func checkPlaybackOutput() throws {
        let reader = AudioRoutes(target: "unused")
        let id = try reader.integer(reader.system, kAudioHardwarePropertyDefaultOutputDevice)
        let name = try reader.string(id, kAudioObjectPropertyName)
        let uid = try reader.string(id, kAudioDevicePropertyDeviceUID)
        guard !name.uppercased().contains("DJI"), !VirtualInputIdentity.isLoopbackUID(uid) else { throw StreamError.invalid("请将系统输出切换为 Mac 扬声器或其他非 DJI 设备后播放") }
    }
}
