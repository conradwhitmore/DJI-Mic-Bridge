import XCTest
@testable import MicBridgeSupport

final class ConnectionStateTests: XCTestCase {
    private func connected() -> ConnectionEvidence {
        var e = ConnectionEvidence(); e.selected = true; e.bluetooth = true; return e
    }
    func testAudioDevicePresenceNeverProvesRecordedVoice() {
        var e = connected(); e.inputAvailable = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .hfpAvailable)
        e.systemAudioActive = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .systemAudioActive)
        e.audioReadable = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .observationUnavailable)
    }
    func testSPPRequiresRecentDecodedAudioEvenWithHFPDevicePresent() {
        var e = connected(); e.session = true; e.inputAvailable = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .connecting)
        e.receivedAudio = true; e.recentAudio = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .streaming)
        e.recentAudio = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 4), .stalled)
    }
    func testLiveTrialCloseTimeoutThenLinkLossAndHFPReturn() {
        var e = connected(); e.session = true; e.closing = true
        var r = RecoveryObservation(); r.begin(now: 0, connected: true)
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 0), .closing)
        e.session = false; e.closing = false; e.closeUnresolved = true; e.inputAvailable = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 8), .closeUnconfirmed)
        // Only an observed link loss retires the unresolved transport in the controller.
        r.observe(connected: false, now: 110); e.bluetooth = false; e.closeUnresolved = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 110), .recovering)
        r.observe(connected: true, inputAvailable: true, now: 114); e.bluetooth = true
        XCTAssertEqual(r.disconnects, 1)
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 114), .hfpAvailable)
    }
    func testDuplicateDisconnectObservationsCountOnlyOneEdge() {
        var r = RecoveryObservation(); r.begin(now: 0, connected: true)
        r.observe(connected: false, now: 1); r.observe(connected: false, now: 2)
        r.begin(now: 3, connected: false)
        XCTAssertEqual(r.started, 0); XCTAssertEqual(r.disconnects, 1)
        r.observe(connected: true, now: 4); r.observe(connected: false, now: 5)
        var e = connected(); e.bluetooth = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 5), .repeatedDisconnects)
    }
    func testNoMandatoryDisconnectForAvailableHFP() {
        var r = RecoveryObservation(); r.begin(now: 0, connected: true)
        var e = connected(); e.inputAvailable = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 1), .hfpAvailable)
        XCTAssertEqual(r.disconnects, 0)
    }
    func testDeadlineDoesNotInventSuccessfulRecovery() {
        var r = RecoveryObservation(); r.begin(now: 0, connected: true)
        XCTAssertEqual(ConnectionPhase.resolve(connected(), recovery: r, now: 179), .recovering)
        XCTAssertEqual(ConnectionPhase.resolve(connected(), recovery: r, now: 180), .recoveryTimedOut)
        var e = connected(); e.inputAvailable = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 200), .hfpAvailable)
    }
    func testLaterPowerOffDoesNotCountAsAnExitFlash() {
        var r = RecoveryObservation(); r.begin(now: 0, connected: true)
        r.observe(connected: true, inputAvailable: true, now: 20)
        r.observe(connected: false, now: 600)
        XCTAssertEqual(r.disconnects, 0)
        XCTAssertEqual(r.laterDisconnects, 1)
        var e = connected(); e.bluetooth = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 600), .disconnected)
    }
    func testLateHFPActivationFlashIsRecordedWithoutInventingEarlyFailure() {
        var r = RecoveryObservation(); r.begin(now: 0, connected: true)
        r.observe(connected: true, now: 185)
        r.observe(connected: false, now: 263)
        r.observe(connected: false, now: 264)
        XCTAssertEqual(r.disconnects, 0)
        XCTAssertEqual(r.laterDisconnects, 1)
        r.observe(connected: true, inputAvailable: true, now: 268)
        var e = connected(); e.inputAvailable = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 268), .hfpAvailable)
        r.observe(connected: false, now: 600)
        XCTAssertEqual(r.laterDisconnects, 2)
        e.bluetooth = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 600), .disconnected)
    }
    func testWindowBoundaryDoesNotCountTheSameDisconnectTwice() {
        var r = RecoveryObservation(); r.begin(now: 0, connected: true)
        r.observe(connected: false, now: 179)
        r.observe(connected: false, now: 180)
        XCTAssertEqual(r.disconnects, 1)
        XCTAssertEqual(r.laterDisconnects, 0)
        r.observe(connected: true, now: 180)
        r.observe(connected: false, now: 180)
        XCTAssertEqual(r.disconnects, 1)
        XCTAssertEqual(r.laterDisconnects, 1)
    }
    func testUnsupportedModelNeverClaimsMic2Mode() {
        var e = connected(); e.supported = false; e.inputAvailable = true; e.systemAudioActive = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .unsupported)
        e.selected = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .noDevice)
    }
    func testLateAudioAvailabilityDoesNotLeavePermanentTimeout() {
        var r = RecoveryObservation(); r.begin(now: 0, connected: true)
        XCTAssertEqual(ConnectionPhase.resolve(connected(), recovery: r, now: 180), .recoveryTimedOut)
        r.observe(connected: true, inputAvailable: true, now: 200)
        XCTAssertEqual(ConnectionPhase.resolve(connected(), recovery: r, now: 300), .bluetoothOnly)
        var e = connected(); e.bluetooth = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: r, now: 400), .disconnected)
    }
}
