import XCTest
@testable import MicBridgeSupport

final class SPPExitPolicyTests: XCTestCase {
    func testWaitForReadinessThenACKBeforeClosingExactlyOnce() {
        var p = SPPExitPolicy(); p.request(now: 0)
        XCTAssertEqual(p.advance(canQuery: false, alreadySent: false, now: 1), .none)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: false, now: 2), .sendCommand)
        XCTAssertFalse(p.closeAuthorized)
        XCTAssertEqual(p.advance(canQuery: false, alreadySent: true, now: 3), .none)
        p.reply(success: true)
        XCTAssertEqual(p.advance(canQuery: false, alreadySent: true, now: 4), .closeChannel)
        XCTAssertTrue(p.closeAuthorized)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: true, now: 5), .none)
    }
    func testPriorDiagnosticACKIsReusedWithoutResending() {
        var p = SPPExitPolicy(); p.reply(success: true)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: true, now: 0), .none)
        p.request(now: 2)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: true, now: 2), .closeChannel)
    }
    func testErrorReplyNeverClosesEvenOnRepeatedExit() {
        var p = SPPExitPolicy(); p.request(now: 0); p.reply(success: false)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: true, now: 1), .fail)
        XCTAssertFalse(p.closeAuthorized)
        p.request(now: 2)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: true, now: 3), .fail)
    }
    func testTimeoutDoesNotCloseOrResendAnUncertainWrite() {
        var p = SPPExitPolicy(); p.request(now: 0)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: false, now: 1), .sendCommand)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: true, now: 10), .none)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: true, now: 11), .fail)
        XCTAssertFalse(p.pending); XCTAssertFalse(p.closeAuthorized)
        p.request(now: 12)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: true, now: 13), .none)
    }
    func testBusyChannelWaitIsBoundedAndRepeatedQuitDoesNotExtendIt() {
        var p = SPPExitPolicy(); p.request(now: 0); p.request(now: 10)
        XCTAssertEqual(p.advance(canQuery: false, alreadySent: false, now: 12), .fail)
        XCTAssertFalse(p.closeAuthorized)
    }
    func testAcknowledgementDoesNotLeakToNewSession() {
        var p = SPPExitPolicy(); p.reply(success: true); p = SPPExitPolicy()
        p.request(now: 0)
        XCTAssertEqual(p.advance(canQuery: true, alreadySent: false, now: 1), .sendCommand)
        XCTAssertFalse(p.closeAuthorized)
    }
}
