import XCTest
@testable import Mini2Protocol

final class AudioSettingsTests: XCTestCase {
    private func status(on: Bool = false, level: UInt8 = 0, tone: UInt8 = 1) -> Mini2SPPStatus {
        var bytes = [UInt8](repeating: 0, count: 22)
        bytes[11] = on ? 0x80 : 0; bytes[15] = (level << 5) | tone
        return Mini2SPPStatus(bytes: bytes)
    }
    private func confirm(_ state: inout MiniAudioSettings, _ value: Mini2SPPStatus, from time: Double) {
        for offset in [0.4, 0.6, 0.8] { state.observe(value, at: time + offset) }
    }
    func testWirePacketsUseRXEncodingAndDoNotUseDUML() {
        let cases: [(MiniAudioCommand, [UInt8])] = [
            (.denoise(false), [0x55,9,0x58,0x2a,0x19,0,0,0x11,0]),
            (.denoise(true), [0x55,9,0x58,0x2b,0x19,0,0,0x11,1]),
            (.level(.weak), [0x55,9,0x58,0x2d,0x19,0,0,0x14,0]),
            (.level(.strong), [0x55,9,0x58,0x2e,0x19,0,0,0x14,1]),
            (.tone(.standard), [0x55,9,0x58,0x33,0x19,0,0,0x19,1]),
            (.tone(.rich), [0x55,9,0x58,0x34,0x19,0,0,0x19,2]),
            (.tone(.bright), [0x55,9,0x58,0x35,0x19,0,0,0x19,3])]
        for (command, frame) in cases {
            let packet = command.packet
            XCTAssertEqual(packet.count, 129)
            XCTAssertEqual(Array(packet.prefix(3)), [0xaa,4,0])
            XCTAssertEqual(Array(packet[3..<12]), frame)
            XCTAssertTrue(packet[12..<128].allSatisfy { $0 == 0 })
            XCTAssertEqual(packet.last, 0xa5)
        }
        XCTAssertEqual(MiniAudioCommand.denoise(true).packet, mini2DenoisePacket(enabled: true))
    }
    func testStrongFromOffConfirmsLevelBeforeEnablingForBothModels() {
        for model in MiniTransmitterModel.allCases {
            var state = MiniAudioSettings(model: model)
            state.observe(status(), at: 0)
            XCTAssertTrue(state.requestNoise(.strong, at: 0.1))
            XCTAssertEqual(state.nextCommand(at: 0.1), .level(.strong))
            XCTAssertNil(state.nextCommand(at: 0.2))
            // Status arriving before write completion cannot confirm a write.
            confirm(&state, status(level: 1), from: 0.1)
            XCTAssertNil(state.nextCommand(at: 1))
            state.writeCompleted(success: true)
            confirm(&state, status(level: 1), from: 1)
            XCTAssertEqual(state.view(at: 1.8).noiseMode, .off)
            XCTAssertEqual(state.nextCommand(at: 1.9), .denoise(true))
            state.writeCompleted(success: true)
            confirm(&state, status(on: true, level: 1), from: 1.9)
            XCTAssertFalse(state.busy)
            XCTAssertEqual(state.view(at: 2.7).noiseMode, .strong)
        }
    }
    func testWeakWhileEnabledOnlyWritesLevelAndOffRetainsLevel() {
        var state = MiniAudioSettings(model: .mini)
        state.observe(status(on: true, level: 1), at: 0)
        XCTAssertTrue(state.requestNoise(.weak, at: 0))
        XCTAssertEqual(state.nextCommand(at: 0), .level(.weak))
        state.writeCompleted(success: true)
        confirm(&state, status(on: true), from: 0)
        XCTAssertFalse(state.busy)
        XCTAssertTrue(state.requestNoise(.off, at: 1))
        XCTAssertEqual(state.nextCommand(at: 1), .denoise(false))
        state.writeCompleted(success: true)
        confirm(&state, status(level: 1), from: 1)
        XCTAssertFalse(state.busy)
        XCTAssertEqual(state.view(at: 1.8).noiseMode, .off)
    }
    func testToneIsMini2OnlyAndUnknownIsNotDisplayedAsStandard() {
        var one = MiniAudioSettings(model: .mini)
        one.observe(status(tone: 2), at: 0)
        XCTAssertNil(one.view(at: 0).tone)
        XCTAssertFalse(one.requestTone(.bright, at: 0)); XCTAssertNil(one.nextCommand(at: 0))
        var two = MiniAudioSettings(model: .mini2)
        two.observe(status(tone: 0), at: 0)
        XCTAssertNil(two.view(at: 0).tone)
        XCTAssertTrue(two.requestTone(.bright, at: 0))
        XCTAssertEqual(two.nextCommand(at: 0), .tone(.bright))
        two.writeCompleted(success: true)
        confirm(&two, status(tone: 3), from: 0)
        XCTAssertFalse(two.busy); XCTAssertEqual(two.view(at: 0.8).tone, .bright)
    }
    func testStaleStateNoopsAndOverlappingRequests() {
        var state = MiniAudioSettings(model: .mini2)
        XCTAssertFalse(state.requestNoise(.weak, at: 0))
        state.observe(status(on: true, level: 3), at: 0)
        XCTAssertNil(state.view(at: 0).noiseMode)
        XCTAssertFalse(state.requestNoise(.strong, at: 2))
        XCTAssertFalse(state.view(at: 2).ready)
        state.observe(status(), at: 3)
        XCTAssertTrue(state.requestNoise(.off, at: 3)); XCTAssertNil(state.nextCommand(at: 3))
        XCTAssertTrue(state.requestTone(.standard, at: 3)); XCTAssertNil(state.nextCommand(at: 3))
        XCTAssertTrue(state.requestNoise(.strong, at: 3))
        XCTAssertFalse(state.requestTone(.bright, at: 3)); XCTAssertFalse(state.requestNoise(.weak, at: 3))
    }
    func testTimeoutWriteFailureAndExitNeverSendQueuedEnable() {
        for failure in ["timeout", "write", "cancel", "stale"] {
            var state = MiniAudioSettings(model: .mini2)
            state.observe(status(), at: 0); _ = state.requestNoise(.strong, at: 0)
            if failure == "stale" {
                XCTAssertNil(state.nextCommand(at: 2))
            } else {
                XCTAssertEqual(state.nextCommand(at: 0), .level(.strong))
                switch failure {
                case "timeout": state.writeCompleted(success: true); state.expire(at: 6)
                case "write": state.writeCompleted(success: false)
                default: state.cancel(); state.writeCompleted(success: true)
                }
            }
            state.observe(status(level: 1), at: 6.1)
            XCTAssertFalse(state.busy); XCTAssertNil(state.nextCommand(at: 6.1))
            XCTAssertEqual(state.view(at: 6.1).noiseMode, .off)
            if failure != "cancel" { XCTAssertNotNil(state.error) }
        }
    }
    func testConfirmationRequiresFreshDistinctStableObservations() {
        var state = MiniAudioSettings(model: .mini2)
        state.observe(status(), at: 0); _ = state.requestTone(.rich, at: 0)
        _ = state.nextCommand(at: 0); state.writeCompleted(success: true)
        for t in [0.01, 0.02, 0.03, 0.4, 0.4, 0.4] { state.observe(status(tone: 2), at: t) }
        XCTAssertTrue(state.busy)
        state.observe(status(tone: 1), at: 0.6)
        state.observe(status(tone: 2), at: 0.8)
        state.observe(status(tone: 2), at: 1)
        XCTAssertTrue(state.busy)
        state.observe(status(tone: 2), at: 1.2)
        XCTAssertFalse(state.busy)
    }
}
