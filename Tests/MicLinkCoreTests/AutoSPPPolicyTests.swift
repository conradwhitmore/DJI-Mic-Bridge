import XCTest
@testable import MicLinkCore

final class AutoSPPPolicyTests: XCTestCase {
    func testDisabledAutoConnectSurvivesLinkLossAndPolicyRecreation() {
        let policy = AutoSPPPolicy()
        policy.markAttempted()
        policy.linkDisconnected()
        for current in [policy, AutoSPPPolicy()] {
            for time in [0.0, 1, 5, 30] {
                XCTAssertFalse(current.shouldConnect(enabled: false, connected: true,
                                                      ready: true, busy: false, now: time))
            }
            // Only an explicit re-enable permits the original settled, single attempt.
            XCTAssertFalse(current.shouldConnect(enabled: true, connected: true,
                                                  ready: true, busy: false, now: 31))
            XCTAssertTrue(current.shouldConnect(enabled: true, connected: true,
                                                 ready: true, busy: false, now: 32))
            XCTAssertFalse(current.shouldConnect(enabled: true, connected: true,
                                                  ready: true, busy: false, now: 33))
        }
    }
}
