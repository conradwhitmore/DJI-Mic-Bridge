// Offline checks using the production MicLinkCore module; no Bluetooth or audio IO.
import Foundation
import MicLinkCore

func require(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: message, code: 1) }
}
func expectFailure(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw NSError(domain: "Expected refusal", code: 1)
}
func pcm(_ url: URL) throws -> [Int16] {
    let data = try Data(contentsOf: url)
    try require(data.count >= 44, "Missing WAV header")
    let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[40 + $1]) << (8 * $1) }
    try require(Int(size) + 44 == data.count, "Header length differs from saved data")
    return stride(from: 44, to: data.count, by: 2).map {
        Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
    }
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-segments-\(UUID())")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let recorder = RecordingSegments()
try require(try recorder.append([.nan]) == nil, "Idle PCM must be discarded")
try require(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "Idle stream wrote a file")
print("PASS idle stream creates no recording")

let first = folder.appendingPathComponent("first.wav")
try recorder.start(url: first, seconds: 0.01) // 480 samples
_ = try recorder.append(Array(repeating: 0.25, count: 200))
let finished = try recorder.append(Array(repeating: 0.5, count: 400))
try require(finished?.samples == 480 && !recorder.isRecording, "Exact limit failed")
try require(try pcm(first) == Array(repeating: 8192, count: 200) + Array(repeating: 16384, count: 280), "Wrong interval saved")
try require(try recorder.stop(reason: "duplicate stop") == nil, "Duplicate stop must be inert")
print("PASS sample limit trims crossing chunk and finishes once")

_ = try recorder.append(Array(repeating: -0.9, count: 700)) // Gap must never leak into next WAV.
let second = folder.appendingPathComponent("second.wav")
try recorder.start(url: second, seconds: 1)
try expectFailure { try recorder.start(url: folder.appendingPathComponent("duplicate.wav"), seconds: 1) }
_ = try recorder.append(Array(repeating: -0.25, count: 240))
let manuallyStopped = try recorder.stop(reason: "manual")
try require(manuallyStopped?.samples == 240, "Manual stop lost samples")
try require(try pcm(second) == Array(repeating: -8192, count: 240), "Gap or prior segment leaked")
print("PASS manual stop and restart isolate segments; duplicate start rejected")

let third = folder.appendingPathComponent("third.wav")
try recorder.start(url: third, seconds: 1)
_ = try recorder.append(Array(repeating: 0.125, count: 120))
let disconnected = try recorder.stop(reason: "connection lost")
try require(disconnected?.samples == 120 && (try pcm(third)).count == 120, "Disconnect failed to finalize partial file")
print("PASS connection loss preserves partial recording")

let empty = folder.appendingPathComponent("empty.wav")
try recorder.start(url: empty, seconds: 1)
let noAudio = try recorder.stop(reason: "empty")
try require(noAudio?.url == nil && !FileManager.default.fileExists(atPath: empty.path), "Empty recording retained")
try expectFailure { try recorder.start(url: first, seconds: 1) }
try require(!recorder.isRecording && (try pcm(first)).count == 480, "Existing file overwritten")
print("PASS empty segments removed and existing recordings protected")

for seconds in [Double.nan, .infinity, 0, -1, 3601] {
    try expectFailure { try recorder.start(url: empty, seconds: seconds) }
}
try recorder.start(url: empty, seconds: 1)
try expectFailure { _ = try recorder.append([.nan]) }
try require(recorder.samples == 0, "Invalid PCM changed sample count")
_ = try recorder.stop(reason: "invalid PCM")
print("PASS invalid limits and non-finite PCM rejected")

let policy = AutoSPPPolicy()
func wantsConnection(_ time: Double, enabled: Bool = true, connected: Bool = true,
                     ready: Bool = true, busy: Bool = false) -> Bool {
    policy.shouldConnect(enabled: enabled, connected: connected, ready: ready, busy: busy, now: time)
}
try require(!wantsConnection(0) && !wantsConnection(0.9) && wantsConnection(1), "Readiness debounce failed")
try require(!wantsConnection(2) && !wantsConnection(50), "Repeated SPP attempt on same link")
print("PASS automatic attach waits for readiness and attempts once per link")
try require(!wantsConnection(51, connected: false), "Opened SPP while Bluetooth disconnected")
try require(!wantsConnection(52) && wantsConnection(53), "Reconnect did not rearm")
print("PASS new Bluetooth connection rearms one automatic attach")
policy.linkDisconnected()
try require(!wantsConnection(60, busy: true) && !wantsConnection(70, busy: true), "Overlapping sessions allowed")
try require(!wantsConnection(71) && wantsConnection(72), "Busy-session release did not debounce")
print("PASS existing session prevents overlapping attach")
try require(!wantsConnection(80, enabled: false) && !wantsConnection(90, enabled: false), "Manual disable ignored")
try require(!wantsConnection(91) && wantsConnection(92), "Enable did not rearm")
print("PASS explicit disable prevents automatic reconnection")
policy.linkDisconnected()
try require(!wantsConnection(100) && !wantsConnection(101, ready: false), "Unready audio allowed")
try require(!wantsConnection(102) && !wantsConnection(102.5) && wantsConnection(103), "Readiness change did not restart debounce")
print("PASS unavailable or active audio delays attach")
policy.linkDisconnected(); policy.markAttempted()
try require(!wantsConnection(110) && !wantsConnection(200), "Failed/manual attempt retried in a loop")
print("PASS failed or manual attempt is not automatically repeated on same link")
