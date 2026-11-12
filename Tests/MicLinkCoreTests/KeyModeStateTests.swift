import XCTest
@testable import MicLinkCore

final class KeyModeStateTests: XCTestCase {
    private func config(recording: Bool = false) -> [UInt8] {
        let flags: UInt8 = recording ? 0xd1 : 0xd0
        return [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,flags,0,12,0,0,flags,0,12,0,0]
    }
    func testEntryRequiresFreshIdleConfigurationAndMatchingACK() {
        var s = Mic2KeyModeState()
        s.setEnabled(true, now: 0)
        XCTAssertEqual(s.request, .audioConfiguration)
        s.sent(); s.receive(.battery, result: .success([80]))
        XCTAssertNil(s.request); XCTAssertTrue(s.busy)
        s.receive(.audioConfiguration, result: .success(config()))
        XCTAssertEqual(s.request, .keyTestOn); XCTAssertNil(s.enabled)
        s.sent(); s.receive(.keyTestOn, result: .success([0,0x43,1,1]))
        XCTAssertEqual(s.enabled, true); XCTAssertFalse(s.busy)
        s.setEnabled(false, now: 1)
        XCTAssertEqual(s.request, .keyTestOff) // No read prerequisite for recovery.
        s.sent(); s.receive(.keyTestOff, result: .success([0,0x43,1,0]))
        XCTAssertEqual(s.enabled, false); XCTAssertFalse(s.busy)
    }
    func testRecordingAndBadACKNeverEnableHotkeys() {
        var s = Mic2KeyModeState()
        s.setEnabled(true, now: 0); s.sent()
        s.receive(.audioConfiguration, result: .success(config(recording: true)))
        XCTAssertNil(s.request); XCTAssertNotNil(s.error); XCTAssertNil(s.enabled)
        s.setEnabled(true, now: 1); s.sent()
        s.receive(.audioConfiguration, result: .success(config())); s.sent()
        s.receive(.keyTestOn, result: .success([0,0x43,1,0]))
        XCTAssertNil(s.request); XCTAssertNotNil(s.error); XCTAssertNil(s.enabled)
    }
    func testTimeoutDoesNotRetryAndCanExplicitlyRecoverWithoutStatus() {
        var s = Mic2KeyModeState()
        s.setEnabled(true, now: 0); s.sent()
        s.receive(.audioConfiguration, result: .success(config())); s.sent()
        s.expire(now: 25)
        s.receive(.keyTestOn, result: .success([0,0x43,1,1]))
        XCTAssertNil(s.enabled); XCTAssertNil(s.request)
        s.setEnabled(false, now: 26)
        XCTAssertEqual(s.request, .keyTestOff)
        s.sent(); s.receive(.keyTestOff, result: .success([0,0x43,1,0]))
        XCTAssertEqual(s.enabled, false)
    }
    func testDisconnectDropsPendingCommandAndNewSessionMustReapply() {
        var s = Mic2KeyModeState()
        s.setEnabled(true, now: 0); s.sent()
        s = Mic2KeyModeState()
        s.receive(.audioConfiguration, result: .success(config()))
        XCTAssertNil(s.request); XCTAssertNil(s.enabled)
        s.setEnabled(true, now: 10)
        XCTAssertEqual(s.request, .audioConfiguration)
    }
}
