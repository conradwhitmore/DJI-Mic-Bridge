import XCTest
@testable import MicLinkCore

final class VibrationStateTests: XCTestCase {
    private func config(_ flags: UInt8 = 0xc0, gain: UInt8 = 12) -> [UInt8] {
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,flags,0,gain,0,0,flags,0,gain,0,0]
    }
    func testInitialReadNeverWritesAndNewSessionHasNoCachedState() {
        var state = Mic2VibrationState()
        state.read(now: 0)
        XCTAssertEqual(state.request?.command, .audioConfiguration)
        state.sent(); XCTAssertNil(state.request)
        state.receive(.audioConfiguration, result: .success(config()))
        XCTAssertEqual(state.enabled, false); XCTAssertFalse(state.busy); XCTAssertNil(state.request)
        state = Mic2VibrationState()
        XCTAssertNil(state.enabled)
    }
    func testToggleUsesFreshReadThenACKThenVerifiedState() {
        var state = Mic2VibrationState()
        state.read(now: 0); state.sent()
        state.receive(.audioConfiguration, result: .success(config()))
        state.setEnabled(true, now: 1)
        XCTAssertEqual(state.enabled, false) // No optimistic switch before readback.
        XCTAssertEqual(state.request?.command, .audioConfiguration)
        state.sent(); state.receive(.audioConfiguration, result: .success(config(gain: 18)))
        XCTAssertEqual(state.request?.command, .vibrationOn)
        XCTAssertEqual(try state.request?.configuration?.vibrationWritePayload(enabled: true)[19], 18)
        state.sent(); state.receive(.vibrationOn, result: .success([0]))
        XCTAssertEqual(state.enabled, false); XCTAssertEqual(state.request?.command, .audioConfiguration)
        state.sent(); state.receive(.audioConfiguration, result: .success(config(0xd0, gain: 18)))
        XCTAssertEqual(state.enabled, true); XCTAssertFalse(state.busy); XCTAssertNil(state.error)
        state.setEnabled(false, now: 2)
        state.sent(); state.receive(.audioConfiguration, result: .success(config(0xd0)))
        XCTAssertEqual(state.request?.command, .vibrationOff)
    }
    func testNoWriteForAlreadyAppliedValueAndNoConcurrentToggle() {
        var state = Mic2VibrationState()
        state.setEnabled(false, now: 0); state.setEnabled(true, now: 1)
        state.sent(); state.receive(.battery, result: .success([50]))
        XCTAssertTrue(state.busy); XCTAssertNil(state.request)
        state.receive(.audioConfiguration, result: .success(config()))
        XCTAssertFalse(state.busy); XCTAssertEqual(state.enabled, false)
    }
    func testRejectedACKAndMismatchNeverReportSuccessOrRetryWrite() {
        for accepted in [false, true] {
            var state = Mic2VibrationState()
            state.setEnabled(true, now: 0); state.sent()
            state.receive(.audioConfiguration, result: .success(config()))
            state.sent()
            state.receive(.vibrationOn, result: accepted ? .success([0]) : .failure(StreamError.invalid("ACK rejected")))
            if accepted {
                state.sent(); state.receive(.audioConfiguration, result: .success(config()))
            }
            XCTAssertNil(state.enabled); XCTAssertFalse(state.busy); XCTAssertNotNil(state.error); XCTAssertNil(state.request)
        }
    }
    func testTimeoutAndDisconnectDiscardPendingWrite() {
        var state = Mic2VibrationState()
        state.setEnabled(true, now: 0); state.sent()
        state.expire(now: 30)
        XCTAssertFalse(state.busy); XCTAssertNotNil(state.error)
        state.receive(.audioConfiguration, result: .success(config()))
        XCTAssertNil(state.request); XCTAssertNil(state.enabled)
        state = Mic2VibrationState()
        state.receive(.vibrationOn, result: .success([0]))
        XCTAssertNil(state.request); XCTAssertNil(state.enabled)
    }
}
