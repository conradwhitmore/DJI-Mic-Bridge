import XCTest
@testable import MicLinkCore

final class DenoiseStateTests: XCTestCase {
    private func config(_ enabled: Bool, gain: UInt8 = 12) -> [UInt8] {
        let d: UInt8 = enabled ? 0x10 : 0
        return [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xd0,d,gain,0,0,0xd0,d,gain,0,0]
    }
    func testSettingNeedsReadWriteACKAndReadbackWithoutTouchingOtherSettings() throws {
        var s = Mic2DenoiseState()
        s.setEnabled(true, now: 0); s.sent()
        s.receive(.audioConfiguration, result: .success(config(false, gain: 18)))
        XCTAssertEqual(s.request?.command, .denoiseOn)
        XCTAssertEqual(try s.request?.configuration?.denoiseWritePayload(enabled: true)[19], 18)
        s.sent(); s.receive(.denoiseOn, result: .success([0]))
        XCTAssertEqual(s.enabled, false)
        XCTAssertEqual(s.request?.command, .audioConfiguration)
        s.sent(); s.receive(.audioConfiguration, result: .success(config(true, gain: 18)))
        XCTAssertEqual(s.enabled, true); XCTAssertFalse(s.busy)
    }
    func testMismatchFailsWithoutRetryAndAlreadyAppliedDoesNotWrite() {
        var s = Mic2DenoiseState()
        s.setEnabled(true, now: 0); s.sent()
        s.receive(.audioConfiguration, result: .success(config(false))); s.sent()
        s.receive(.denoiseOn, result: .success([0])); s.sent()
        s.receive(.audioConfiguration, result: .success(config(false)))
        XCTAssertNotNil(s.error); XCTAssertNil(s.enabled); XCTAssertNil(s.request)
        s.setEnabled(true, now: 1); s.sent()
        s.receive(.audioConfiguration, result: .success(config(true)))
        XCTAssertEqual(s.enabled, true); XCTAssertNil(s.request)
    }
    func testTimeoutAndResetDiscardLateReplies() {
        var s = Mic2DenoiseState()
        s.setEnabled(true, now: 0); s.sent(); s.expire(now: 30)
        s.receive(.audioConfiguration, result: .success(config(false)))
        XCTAssertNil(s.request); XCTAssertNotNil(s.error)
        s = Mic2DenoiseState()
        s.receive(.denoiseOn, result: .success([0]))
        XCTAssertNil(s.enabled); XCTAssertNil(s.request)
    }
}
