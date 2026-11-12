import XCTest
@testable import MicBridgeSupport

final class SPPResumePolicyTests: XCTestCase {
    func testWorkingManualSessionResumesOnlyAfterLinkLoss() {
        var p = SPPResumePolicy()
        p.begin(target: "A")
        XCTAssertFalse(p.shouldResume(target: "A"))
        p.audioReceived(target: "A")
        XCTAssertFalse(p.shouldResume(target: "A"))
        p.linkLost(target: "A")
        XCTAssertTrue(p.shouldResume(target: "A"))
        p.linkLost(target: "A") // duplicate notifications are harmless
        XCTAssertTrue(p.shouldResume(target: "A"))
        p.begin(target: "A") // consumed by the new connection attempt
        XCTAssertFalse(p.shouldResume(target: "A"))
        p.linkLost(target: "A") // failure before new audio cannot cause a retry loop
        XCTAssertFalse(p.shouldResume(target: "A"))
    }
    func testFailedOpenNeverArmsResume() {
        var p = SPPResumePolicy(); p.begin(target: "A"); p.linkLost(target: "A")
        XCTAssertFalse(p.shouldResume(target: "A"))
    }
    func testExitAndCommandCancellationSurvivesLateCallbacksAndReconnection() {
        var p = SPPResumePolicy(); p.begin(target: "A"); p.audioReceived(target: "A")
        p.cancel() // same operation used before 12/65, manual exit and HFP capture
        p.audioReceived(target: "A"); p.linkLost(target: "A")
        XCTAssertFalse(p.shouldResume(target: "A"))
        p.audioReceived(target: "A"); p.linkLost(target: "A")
        XCTAssertFalse(p.shouldResume(target: "A"))
    }
    func testPendingResumeCanBeCancelledAndDoesNotSurviveRestart() {
        var p = SPPResumePolicy(); p.begin(target: "A"); p.audioReceived(target: "A"); p.linkLost(target: "A")
        p.cancel()
        XCTAssertFalse(p.shouldResume(target: "A"))
        XCTAssertFalse(SPPResumePolicy().shouldResume(target: "A"))
    }
    func testDeviceIsolationAndRepeatedPowerCycles() {
        var p = SPPResumePolicy()
        for _ in 0..<3 {
            p.begin(target: "A"); p.audioReceived(target: "B"); p.linkLost(target: "A")
            XCTAssertFalse(p.shouldResume(target: "A"))
            p.audioReceived(target: "A"); p.linkLost(target: "B")
            XCTAssertFalse(p.shouldResume(target: "A"))
            p.linkLost(target: "A")
            XCTAssertTrue(p.shouldResume(target: "A"))
            XCTAssertFalse(p.shouldResume(target: "B"))
        }
        p.begin(target: "B")
        XCTAssertFalse(p.shouldResume(target: "A"))
        XCTAssertFalse(p.shouldResume(target: "B"))
    }
}
