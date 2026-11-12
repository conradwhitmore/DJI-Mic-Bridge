import XCTest
@testable import MicLinkCore

final class RFCOMMCloseCoordinatorTests: XCTestCase {
    private final class Harness {
        var requests: [UInt64] = []
        var outcomes: [RFCOMMCloseCoordinator.Outcome] = []
        var closeResult: Int32 = 0
        var duringClose: ((UInt64) -> Void)?
        var duringOutcome: ((RFCOMMCloseCoordinator.Outcome) -> Void)?
        let timeout: TimeInterval

        init(timeout: TimeInterval = 8) { self.timeout = timeout }

        lazy var coordinator = RFCOMMCloseCoordinator(timeout: timeout, requestClose: { [unowned self] id in
            self.requests.append(id)
            self.duringClose?(id)
            return self.closeResult
        }, onOutcome: { [unowned self] outcome in
            self.outcomes.append(outcome)
            self.duringOutcome?(outcome)
        })

        func open(_ id: UInt64 = 1) {
            coordinator.openingStarted()
            coordinator.channelAvailable(id: id)
            coordinator.openingCompleted(id: id, success: true)
        }
    }

    func testCancelBeforeAnyOpenAttemptIsNotOpened() {
        let h = Harness()
        h.coordinator.stop(now: 10)
        h.coordinator.stop(now: 20)
        h.coordinator.tick(now: 100)
        XCTAssertEqual(h.requests, [])
        XCTAssertEqual(h.outcomes, [.notOpened])
    }

    func testFailedOpenRequestIsConfirmedWithoutClose() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.openingRequestFailed()
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.stop(now: 0)
        XCTAssertEqual(h.requests, [])
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testPendingCancellationClosesAvailableObjectAndWaitsForOpenFailure() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.stop(now: 0)
        XCTAssertEqual(h.requests, [1])
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [], "The asynchronous open is still pending")
        h.coordinator.openingCompleted(id: 1, success: false)
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testCancellationBeforeChannelIsAvailableStillClosesIt() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.stop(now: 0)
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.channelAvailable(id: 1)
        XCTAssertEqual(h.requests, [1])
        h.coordinator.openingRequestFailed()
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testOpenFailureTerminatesPendingCancellationWithoutCloseEvent() {
        let h = Harness()
        h.closeResult = -1
        h.coordinator.openingStarted()
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.stop(now: 0)
        h.coordinator.openingCompleted(id: nil, success: false)
        XCTAssertEqual(h.requests, [1])
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testLateOpenAfterCancellationRequiresOneMoreClose() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.stop(now: 0)
        h.coordinator.channelClosed(id: 1)
        h.coordinator.openingCompleted(id: 1, success: true)
        XCTAssertEqual(h.requests, [1, 1])
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testLateOpenWithoutFirstCloseEventAlsoRequiresOneMoreClose() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.stop(now: 0)
        h.coordinator.openingCompleted(id: 1, success: true)
        h.coordinator.openingCompleted(id: 1, success: true)
        h.coordinator.channelAvailable(id: 1)
        XCTAssertEqual(h.requests, [1, 1])
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testLateOpenWithFirstKnownIdentityNeedsOnlyOneClose() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.stop(now: 0)
        h.coordinator.openingCompleted(id: 1, success: true)
        XCTAssertEqual(h.requests, [1])
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testNormalCloseRequiresEventDespiteSuccessfulRequest() {
        let h = Harness()
        h.open()
        h.coordinator.stop(now: 10)
        h.coordinator.stop(now: 11)
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.openingCompleted(id: 1, success: true)
        XCTAssertEqual(h.requests, [1])
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.tick(now: 17.99)
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testSuccessfulCloseRequestWithoutEventTimesOutOnce() {
        let h = Harness()
        h.open()
        h.coordinator.stop(now: 10)
        h.coordinator.stop(now: 17)
        h.coordinator.tick(now: 18)
        h.coordinator.tick(now: 100)
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.requests, [1])
        XCTAssertEqual(h.outcomes, [.unconfirmed])
    }

    func testFailedCloseRequestDoesNotRetryAndTimesOut() {
        let h = Harness()
        h.closeResult = -1
        h.open()
        h.coordinator.stop(now: 0)
        h.coordinator.tick(now: 7)
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.openingCompleted(id: 1, success: true)
        h.coordinator.tick(now: 8)
        XCTAssertEqual(h.requests, [1])
        XCTAssertEqual(h.outcomes, [.unconfirmed])
    }

    func testCloseEventConfirmsEvenWhenRequestReturnedFailure() {
        let h = Harness()
        h.closeResult = -1
        h.open()
        h.coordinator.stop(now: 0)
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testSynchronousCloseCallbackAndReentrantStopAreSafe() {
        let h = Harness()
        h.open()
        h.duringClose = { id in
            h.coordinator.stop(now: 1)
            h.coordinator.channelAvailable(id: id)
            h.coordinator.channelClosed(id: id)
        }
        h.duringOutcome = { _ in
            h.coordinator.stop(now: 1)
            h.coordinator.tick(now: 100)
            h.coordinator.channelClosed(id: 1)
        }
        h.coordinator.stop(now: 0)
        XCTAssertEqual(h.requests, [1])
        XCTAssertEqual(h.outcomes, [.confirmed])
        h.duringClose = nil
        h.duringOutcome = nil
    }

    func testSynchronousCloseWhileOpeningDoesNotFinishPendingRequest() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.channelAvailable(id: 1)
        h.duringClose = { h.coordinator.channelClosed(id: $0) }
        h.coordinator.stop(now: 0)
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.openingCompleted(id: 1, success: true)
        XCTAssertEqual(h.requests, [1, 1])
        XCTAssertEqual(h.outcomes, [.confirmed])
        h.duringClose = nil
    }

    func testSynchronousLateOpenInsideCloseIsBounded() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.channelAvailable(id: 1)
        h.duringClose = { id in
            if h.requests.count == 1 {
                h.coordinator.openingCompleted(id: id, success: true)
            } else {
                h.coordinator.openingCompleted(id: id, success: true)
                h.coordinator.channelClosed(id: id)
            }
        }
        h.coordinator.stop(now: 0)
        XCTAssertEqual(h.requests, [1, 1])
        XCTAssertEqual(h.outcomes, [.confirmed])
        h.duringClose = nil
    }

    func testUnexpectedPeerCloseBeforeStopIsAlreadyConfirmed() {
        let h = Harness()
        h.open()
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.stop(now: 0)
        XCTAssertEqual(h.requests, [])
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testUnrelatedCloseDoesNotConfirmTheActiveChannel() {
        let h = Harness()
        h.open()
        h.coordinator.stop(now: 0)
        h.coordinator.channelClosed(id: 2)
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testPendingOpenTimesOutEvenAfterItsCloseEvent() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.stop(now: 0)
        h.coordinator.channelClosed(id: 1)
        h.coordinator.tick(now: 8)
        XCTAssertEqual(h.outcomes, [.unconfirmed])
        h.coordinator.openingCompleted(id: 1, success: false)
        XCTAssertEqual(h.outcomes, [.unconfirmed])
    }

    func testLateOpenAfterTimeoutStillClosesButNeverReportsAgain() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.stop(now: 0)
        h.coordinator.channelClosed(id: 1)
        h.coordinator.tick(now: 8)
        XCTAssertEqual(h.outcomes, [.unconfirmed])
        h.coordinator.openingCompleted(id: 1, success: true)
        XCTAssertEqual(h.requests, [1, 1])
        for _ in 0..<10 {
            h.coordinator.channelClosed(id: 1)
            h.coordinator.openingCompleted(id: 1, success: true)
            h.coordinator.channelAvailable(id: 1)
            h.coordinator.stop(now: 20)
            h.coordinator.tick(now: 100)
        }
        XCTAssertEqual(h.requests, [1, 1])
        XCTAssertEqual(h.outcomes, [.unconfirmed])
    }

    func testChannelAppearingAfterTimeoutStillGetsFiniteCleanup() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.stop(now: 0)
        h.coordinator.tick(now: 8)
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.openingCompleted(id: 1, success: true)
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.requests, [1, 1])
        XCTAssertEqual(h.outcomes, [.unconfirmed])
    }

    func testDuplicateNotificationsAfterConfirmationDoNotCloseAgain() {
        let h = Harness()
        h.open()
        h.coordinator.stop(now: 0)
        h.coordinator.channelClosed(id: 1)
        for _ in 0..<10 {
            h.coordinator.openingStarted()
            h.coordinator.openingCompleted(id: 1, success: true)
            h.coordinator.openingCompleted(id: nil, success: false)
            h.coordinator.openingRequestFailed()
            h.coordinator.channelAvailable(id: 1)
            h.coordinator.channelClosed(id: 1)
        }
        XCTAssertEqual(h.requests, [1])
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testSuccessWithNoIdentityWaitsForUsableChannel() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.stop(now: 0)
        h.coordinator.openingCompleted(id: nil, success: true)
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.channelAvailable(id: 1)
        XCTAssertEqual(h.requests, [1])
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testEveryObservedObjectMustBeResolved() {
        let h = Harness()
        h.coordinator.openingStarted()
        h.coordinator.channelAvailable(id: 1)
        h.coordinator.stop(now: 0)
        h.coordinator.openingCompleted(id: 2, success: true)
        XCTAssertEqual(h.requests, [1, 2])
        h.coordinator.channelClosed(id: 2)
        XCTAssertEqual(h.outcomes, [])
        h.coordinator.channelClosed(id: 1)
        XCTAssertEqual(h.outcomes, [.confirmed])
    }

    func testZeroTimeoutStillAttemptsCloseBeforeReporting() {
        let h = Harness(timeout: 0)
        h.open()
        h.coordinator.stop(now: 10)
        XCTAssertEqual(h.requests, [1])
        XCTAssertEqual(h.outcomes, [.unconfirmed])
    }
}
