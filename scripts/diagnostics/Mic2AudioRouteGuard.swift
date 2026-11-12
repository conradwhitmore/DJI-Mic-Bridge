// Research routing guard. Reads CoreAudio properties; never starts audio IO.
// Keeps the existing non-target input/output/system-output selections during a bounded test.
import Foundation
import CoreAudio
import Darwin

setbuf(stdout, nil)
let hardware = AudioObjectID(kAudioObjectSystemObject)
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}
func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var property = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
    if status != noErr { throw NSError(domain: "CoreAudio", code: Int(status)) }
    return value
}
func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var property = address(selector), value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
    }
    if status != noErr { throw NSError(domain: "CoreAudio", code: Int(status)) }
    return value as String
}
func devices() throws -> [AudioObjectID] {
    var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(hardware, &property, 0, nil, &size)
    if status != noErr { throw NSError(domain: "CoreAudio", code: Int(status)) }
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    status = values.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(hardware, &property, 0, nil, &size, $0.baseAddress!)
    }
    if status != noErr { throw NSError(domain: "CoreAudio", code: Int(status)) }
    return values
}
func normalize(_ value: String) -> String {
    value.uppercased().replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
}
let args = CommandLine.arguments
guard args.count == 4, let limit = Double(args[2]), (10...600).contains(limit),
      args[1].range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil else {
    print("Usage: mic2-audio-route-guard DEVICE_ADDRESS SECONDS STATUS_FILE"); exit(2)
}
let target = normalize(args[1]), statusURL = URL(fileURLWithPath: args[3])
let selectors: [(String, AudioObjectPropertySelector)] = [
    ("input", kAudioHardwarePropertyDefaultInputDevice),
    ("output", kAudioHardwarePropertyDefaultOutputDevice),
    ("system_output", kAudioHardwarePropertyDefaultSystemOutputDevice)
]
var locked: [AudioObjectPropertySelector: AudioObjectID] = [:]
var names: [String: String] = [:]
do {
    for (name, selector) in selectors {
        let device = try integer(hardware, selector)
        guard device != kAudioObjectUnknown,
              !(try normalize(string(device, kAudioDevicePropertyDeviceUID))).contains(target),
              try integer(device, kAudioDevicePropertyDeviceIsAlive) == 1 else {
            throw NSError(domain: "UnsafeInitialRoute", code: 1)
        }
        locked[selector] = device
        names[name] = try string(device, kAudioObjectPropertyName)
    }
} catch { print("Refused: existing routes must be available non-target devices. \(error)"); exit(2) }

umask(0o077)
let started = ProcessInfo.processInfo.systemUptime
var contaminated = false, lastPrint = 0.0, stopped = false
func tick(_ final: Bool = false) {
    guard !stopped else { return }
    let now = ProcessInfo.processInfo.systemUptime
    var restored: [String] = [], present = false, running = false, errorText: String?
    do {
        // Inspect activity before restoring routes: do not hide an observed audio activation.
        for device in try devices() {
            let uid = try string(device, kAudioDevicePropertyDeviceUID)
            if normalize(uid).contains(target) {
                present = true
                if try integer(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 { running = true }
            }
        }
        if running { contaminated = true }
        for (name, selector) in selectors {
            let expected = locked[selector]!
            guard try integer(expected, kAudioDevicePropertyDeviceIsAlive) == 1 else {
                throw NSError(domain: "LockedRouteUnavailable", code: 1)
            }
            if try integer(hardware, selector) != expected {
                var property = address(selector), value = expected
                let result = AudioObjectSetPropertyData(hardware, &property, 0, nil,
                                                       UInt32(MemoryLayout<AudioObjectID>.size), &value)
                guard result == noErr, try integer(hardware, selector) == expected else {
                    throw NSError(domain: "RouteRestoreFailed", code: Int(result))
                }
                restored.append(name)
            }
        }
    } catch { errorText = String(describing: error); contaminated = true }
    let expired = final || now - started >= limit
    var result: [String: Any] = ["kind": "audio_guard", "pid": getpid(),
        "epoch": Date().timeIntervalSince1970, "monotonic": now,
        "elapsed": now - started, "target_address": target, "target_present": present, "target_running": running,
        "contaminated": contaminated, "safe": !expired && !contaminated && errorText == nil,
        "finished": expired, "routes": names, "restored_routes": restored]
    if let errorText = errorText { result["error"] = errorText }
    do {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try data.write(to: statusURL, options: .atomic)
        if now - lastPrint >= 5 || !restored.isEmpty || contaminated || expired {
            print(String(decoding: data, as: UTF8.self)); lastPrint = now
        }
    } catch { print("Guard status write failed: \(error)"); exit(3) }
    if expired { stopped = true; exit(0) }
}
for (_, selector) in selectors {
    var property = address(selector)
    let status = AudioObjectAddPropertyListenerBlock(hardware, &property, .main) { _, _ in tick() }
    guard status == noErr else { print("Guard listener failed: \(status)"); exit(2) }
}
var devicesProperty = address(kAudioHardwarePropertyDevices)
let listenerStatus = AudioObjectAddPropertyListenerBlock(hardware, &devicesProperty, .main) { _, _ in tick() }
guard listenerStatus == noErr else { print("Device listener failed: \(listenerStatus)"); exit(2) }
var signalSources: [DispatchSourceSignal] = []
for number in [SIGINT, SIGTERM] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { tick(true) }
    source.resume(); signalSources.append(source)
}
let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in tick() }
tick()
RunLoop.main.run()
