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
    private(set) var targetAudioActive = false
    // Input stays on the bridge; output protection accepts every non-DJI choice.
    private let selectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDefaultInputDevice]
    private let outputSelectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice]
    private var outputUIDs: [AudioObjectPropertySelector: String] = [:]
    private var outputListeners: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock] = [:]
    private var outputProtection = false
    private var updatingOutputs = false
    deinit { endOutputProtection() }
    func endOutputProtection() {
        outputProtection = false
        for (selector, listener) in outputListeners {
            var address = property(selector)
            AudioObjectRemovePropertyListenerBlock(system, &address, DispatchQueue.main, listener)
        }
        outputListeners.removeAll()
    }
    private func beginOutputProtection() {
        guard !outputProtection else { return }
        outputProtection = true
        for selector in outputSelectors {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.outputProtection else { return }
                // Periodic session checks report failures; this listener minimizes
                // the interval in which a newly selected DJI output can remain active.
                try? self.protectOutputs()
            }
            var address = property(selector)
            if AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main, listener) == noErr {
                outputListeners[selector] = listener
            }
        }
    }
    private func protectOutputs() throws {
        guard outputProtection, !updatingOutputs else { return }
        updatingOutputs = true
        defer { updatingOutputs = false }
        let candidates = try devices().compactMap { id -> SPPOutputSelection.Candidate? in
            guard hasStream(id, input: false), try integer(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                  try !isDJI(id) else { return nil }
            let uid = try string(id, kAudioDevicePropertyDeviceUID)
            return .init(id: id, uid: uid,
                builtIn: (try? integer(id, kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeBuiltIn,
                fallback: !VirtualInputIdentity.isLoopbackUID(uid))
        }
        var failures: [String] = []
        for selector in outputSelectors {
            do {
                let current = try integer(system, selector)
                guard let chosen = SPPOutputSelection.choose(candidates, current: current, previousUID: outputUIDs[selector]),
                      let candidate = candidates.first(where: { $0.id == chosen }) else {
                    throw StreamError.invalid("没有可用的非 DJI 输出设备")
                }
                if current != chosen {
                    // Respect an allowed selection made while enumerating devices.
                    let latest = try integer(system, selector)
                    if let allowed = candidates.first(where: { $0.id == latest }) {
                        outputUIDs[selector] = allowed.uid; continue
                    }
                    var address = property(selector), value = chosen
                    guard AudioObjectSetPropertyData(system, &address, 0, nil, 4, &value) == noErr else {
                        throw StreamError.invalid("无法将 DJI 输出切回其他设备")
                    }
                    let actual = try integer(system, selector)
                    guard let accepted = candidates.first(where: { $0.id == actual }) else {
                        throw StreamError.invalid("非 DJI 输出切换未生效")
                    }
                    outputUIDs[selector] = accepted.uid
                } else { outputUIDs[selector] = candidate.uid }
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw StreamError.invalid(failures.joined(separator: "；")) }
    }
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
    func lock(allowTargetAudio: Bool = false) throws {
        let all = try devices()
        for device in all where try isTarget(device) {
            guard try allowTargetAudio || integer(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 else {
                throw StreamError.invalid("Mic 2 正被系统音频使用。请退出录音软件和声音输入电平页，再试。")
            }
        }
        let selector = kAudioHardwarePropertyDefaultInputDevice
        let chosen = try preferredInput(all, current: integer(system, selector))
        lockedUIDs[chosen] = try string(chosen, kAudioDevicePropertyDeviceUID)
        locked[selector] = chosen
        beginOutputProtection()
        try check(requirePresent: true, allowTargetAudio: allowTargetAudio)
        description = "系统输入：\(try string(chosen, kAudioObjectPropertyName))"
    }
    func check(requirePresent: Bool, allowTargetAudio: Bool = false, allowDefaultInput: Bool = false) throws {
        // Record the unsafe condition, but still restore every available default.
        // Activity detection must not bypass the recovery path.
        var observationError: Error?
        targetAudioActive = false
        do {
            let all = try devices()
            var present = false
            for device in all where try isTarget(device) {
                present = true
                if try integer(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 {
                    targetAudioActive = true
                    if !allowTargetAudio { observationError = StreamError.invalid("检测到 Mic 2 系统音频活动，已停止 SPP") }
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
        // any hardware input. Outputs track the user's latest non-DJI selection.
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
        do { try protectOutputs() } catch { messages.append(error.localizedDescription) }
        if let inputSelectionError { messages.append(inputSelectionError.localizedDescription) }
        if !messages.isEmpty { throw StreamError.invalid(messages.joined(separator: "；")) }
    }
    struct OutputDevice {
        let uid: String
        let name: String
        let isDJI: Bool
        let selected: Bool
    }
    func outputDevices() throws -> [OutputDevice] {
        let current = try integer(system, kAudioHardwarePropertyDefaultOutputDevice)
        return try devices().compactMap { id in
            guard hasStream(id, input: false), try integer(id, kAudioDevicePropertyDeviceIsAlive) == 1 else { return nil }
            return OutputDevice(uid: try string(id, kAudioDevicePropertyDeviceUID),
                name: try string(id, kAudioObjectPropertyName), isDJI: try isDJI(id), selected: id == current)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func selectOutput(uid: String, excludingDJI: Bool) throws {
        guard let id = try devices().first(where: { try string($0, kAudioDevicePropertyDeviceUID) == uid }),
              hasStream(id, input: false), try integer(id, kAudioDevicePropertyDeviceIsAlive) == 1 else {
            throw StreamError.invalid("输出设备已不可用，请重新选择")
        }
        guard try !excludingDJI || !isDJI(id) else {
            throw StreamError.invalid("SPP 连接期间不能选择 DJI 输出")
        }
        var address = property(kAudioHardwarePropertyDefaultOutputDevice), value = id
        guard AudioObjectSetPropertyData(system, &address, 0, nil, 4, &value) == noErr,
              try integer(system, kAudioHardwarePropertyDefaultOutputDevice) == id else {
            throw StreamError.invalid("无法切换输出设备")
        }
    }
    static func checkPlaybackOutput() throws {
        let reader = AudioRoutes(target: "unused")
        let id = try reader.integer(reader.system, kAudioHardwarePropertyDefaultOutputDevice)
        let name = try reader.string(id, kAudioObjectPropertyName)
        let uid = try reader.string(id, kAudioDevicePropertyDeviceUID)
        guard !name.uppercased().contains("DJI"), !VirtualInputIdentity.isLoopbackUID(uid) else { throw StreamError.invalid("请将系统输出切换为 Mac 扬声器或其他非 DJI 设备后播放") }
    }
}
