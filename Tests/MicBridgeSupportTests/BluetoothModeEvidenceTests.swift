import XCTest
@testable import MicBridgeSupport

final class BluetoothModeEvidenceTests: XCTestCase {
    private let target = "02-11-22-A1-B2-C3"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func date(_ delta: Double) -> Date { start.addingTimeInterval(delta) }
    func testRecordedMic2LifecycleMessages() {
        XCTAssertEqual(BluetoothModeEvent.parse("Creating HFPAudioDevice for device 02:11:22:A1:B2:C3 with codec: mSBC, HandsfreeAoS 0", target: target), .hfpCreated)
        XCTAssertEqual(BluetoothModeEvent.parse("Received voice audio connected event for device 02:11:22:A1:B2:C3", target: target), .voiceConnected)
        XCTAssertEqual(BluetoothModeEvent.parse("Received voice disconnection event for device 02:11:22:A1:B2:C3", target: target), .voiceDisconnected)
    }
    func testOtherDeviceAndPrivateLogsCannotSupplyEvidence() {
        for message in ["Received voice audio connected event for device 11:22:33:44:55:66", "Received voice audio connected event for device <private>", "RegisterScoChannel codecID: mSBC", "Initiating SCO connection with delay of 0 milliseconds, codec 2, lastCodec 0", "Got voice connection info. Sending packet type 2 for device 02:11:22:A1:B2:C3"] {
            XCTAssertNil(BluetoothModeEvent.parse(message, target: target))
        }
        XCTAssertNil(BluetoothModeEvent.parse("Creating HFPAudioDevice for device 02:11:22:A1:B2:C3 and 11:22:33:44:55:66", target: target))
    }
    func testFailedACLConnectIsNotSuccessfulBoundary() {
        XCTAssertNil(BluetoothModeEvent.parse("ACL connected: 02:11:22:A1:B2:C3, result 1", target: target))
        XCTAssertEqual(BluetoothModeEvent.parse("ACL connected: 02:11:22:A1:B2:C3, result 0", target: target), .aclConnected)
    }
    func testExactHFPEndpointIdentityNotNameOrSampleRate() {
        XCTAssertTrue(BluetoothModeEvidence.isHFPEndpoint(uid: "02:11:22:A1:B2:C3-tsco", target: target))
        for uid in ["02:11:22:A1:B2:C3", "02:11:22:A1:B2:C3-taac", "11:22:33:44:55:66-tsco", "virtual-02:11:22:A1:B2:C3-tsco", "DJI Mic 2 16000"] {
            XCTAssertFalse(BluetoothModeEvidence.isHFPEndpoint(uid: uid, target: target))
        }
    }
    func testRejectHistoryLateDeliveryFutureAndOutOfOrder() {
        var e = BluetoothModeEvidence(since: start)
        XCTAssertFalse(e.accept(.voiceConnected, at: date(-1), now: start))
        XCTAssertFalse(e.accept(.voiceConnected, at: date(1), now: date(20)))
        XCTAssertFalse(e.accept(.voiceConnected, at: date(5), now: date(1)))
        XCTAssertTrue(e.accept(.voiceDisconnected, at: date(3), now: date(3)))
        XCTAssertFalse(e.accept(.voiceConnected, at: date(2), now: date(3)))
        XCTAssertFalse(e.voiceConnected)
    }
    func testDisconnectRetainsEndpointButDropsVoiceEvidence() {
        var e = BluetoothModeEvidence(since: start)
        e.accept(.voiceConnected, at: date(1), now: date(1))
        e.accept(.voiceDisconnected, at: date(2), now: date(2))
        XCTAssertTrue(e.hfpCreated); XCTAssertFalse(e.voiceConnected)
        e.accept(.aclDisconnected, at: date(3), now: date(3))
        XCTAssertFalse(e.hfpCreated); XCTAssertFalse(e.voiceConnected)
    }
    func testReconnectAndSelectionResetDiscardOldEvidence() {
        var e = BluetoothModeEvidence(since: start)
        e.accept(.voiceConnected, at: date(1), now: date(1))
        e.accept(.aclConnected, at: date(2), now: date(2))
        XCTAssertFalse(e.voiceConnected); XCTAssertFalse(e.hfpCreated)
        e.reset(since: date(5))
        XCTAssertFalse(e.accept(.voiceConnected, at: date(4), now: date(6)))
        XCTAssertNil(e.lastEvent)
    }
    func testIdleInvalidatesPreviousVoiceSessionAfterActivityGrace() {
        var e = BluetoothModeEvidence(since: start)
        e.accept(.voiceConnected, at: date(1), now: date(1))
        e.reconcile(inputAvailable: true, audioActive: false, now: date(2))
        XCTAssertTrue(e.voiceConnected)
        e.reconcile(inputAvailable: true, audioActive: false, now: date(5))
        XCTAssertFalse(e.voiceConnected)
        e.reconcile(inputAvailable: true, audioActive: true, now: date(6))
        XCTAssertFalse(e.voiceConnected)
    }
    func testActiveVoiceEvidenceRequiresCurrentSystemInputAndActivity() {
        var e = ConnectionEvidence(); e.selected = true; e.bluetooth = true
        e.inputAvailable = true; e.hfpIdentified = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .hfpReady)
        e.hfpVoiceConnected = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .hfpReady)
        e.systemAudioActive = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .hfpVoiceActive)
        e.hfpVoiceConnected = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .systemAudioActive)
        e.inputAvailable = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .bluetoothOnly)
    }
    func testSPPAndCloseWarningsTakePriorityOverHFPEvidence() {
        var e = ConnectionEvidence(); e.selected = true; e.bluetooth = true
        e.inputAvailable = true; e.hfpIdentified = true; e.hfpVoiceConnected = true; e.systemAudioActive = true
        e.session = true; e.sppReady = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .sppConnected)
        e.receivedAudio = true; e.recentAudio = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .streaming)
        e.closing = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .closing)
        e.closing = false; e.session = false; e.closeUnresolved = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .closeUnconfirmed)
    }

    func testExplicitHFPTestUsesRealAudioAndNeverMasksDisconnectOrSPP() {
        var e = ConnectionEvidence(); e.selected = true; e.bluetooth = true
        e.hfpCapture = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .hfpTesting)
        e.hfpRecentAudio = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .hfpRecording)
        e.bluetooth = false
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .disconnected)
        e.bluetooth = true; e.closeUnresolved = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .closeUnconfirmed)
        e.closeUnresolved = false; e.session = true
        XCTAssertEqual(ConnectionPhase.resolve(e, recovery: .init(), now: 0), .connecting)
    }
}
