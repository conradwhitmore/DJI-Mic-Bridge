import XCTest
@testable import MicLinkCore

final class LockedRouteRestorerTests: XCTestCase {
    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class Harness {
        var defaults: [UInt32: UInt32] = [1: 91, 2: 92, 3: 93]
        var unavailable = Set<UInt32>()
        var availabilityErrors = Set<UInt32>()
        var readErrors = Set<UInt32>()
        var writeErrors = Set<UInt32>()
        var verificationErrors = Set<UInt32>()
        var ignoredWrites = Set<UInt32>()
        var operations: [String] = []
        var writes: [UInt32] = []

        func restore(selectors: [UInt32] = [1, 2, 3],
                     locked: [UInt32: UInt32] = [1: 11, 2: 12, 3: 13]) -> [LockedRouteRestorer.Failure] {
            LockedRouteRestorer.restore(selectors: selectors, locked: locked, isAlive: { device in
                self.operations.append("alive:\(device)")
                if self.availabilityErrors.contains(device) { throw TestFailure(message: "availability failed") }
                return !self.unavailable.contains(device)
            }, readDefault: { selector in
                self.operations.append("read:\(selector)")
                if self.readErrors.contains(selector) { throw TestFailure(message: "read failed") }
                if self.writes.contains(selector), self.verificationErrors.contains(selector) {
                    throw TestFailure(message: "verification read failed")
                }
                return self.defaults[selector] ?? 0
            }, writeDefault: { selector, device in
                self.operations.append("write:\(selector):\(device)")
                self.writes.append(selector)
                if self.writeErrors.contains(selector) { throw TestFailure(message: "write failed") }
                if !self.ignoredWrites.contains(selector) { self.defaults[selector] = device }
            })
        }
    }

    func testMatchingDefaultsAreNotWritten() {
        let h = Harness()
        h.defaults = [1: 11, 2: 12, 3: 13]
        XCTAssertEqual(h.restore(), [])
        XCTAssertEqual(h.writes, [])
        XCTAssertEqual(h.operations, ["alive:11", "read:1", "alive:12", "read:2", "alive:13", "read:3"])
    }

    func testEachChangedDefaultIsWrittenThenVerified() {
        let h = Harness()
        XCTAssertEqual(h.restore(), [])
        XCTAssertEqual(h.defaults, [1: 11, 2: 12, 3: 13])
        XCTAssertEqual(h.operations, [
            "alive:11", "read:1", "write:1:11", "read:1",
            "alive:12", "read:2", "write:2:12", "read:2",
            "alive:13", "read:3", "write:3:13", "read:3"
        ])
    }

    func testUnavailableDeviceIsNotReadOrWrittenAndRemainingRoutesRecover() {
        let h = Harness()
        h.unavailable = [11]
        let failures = h.restore()
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.selector, 1)
        XCTAssertEqual(failures.first?.expectedDevice, 11)
        XCTAssertEqual(failures.first?.stage, .availability)
        XCTAssertFalse(h.operations.contains("read:1"))
        XCTAssertEqual(h.writes, [2, 3])
        XCTAssertEqual(h.defaults[2], 12)
        XCTAssertEqual(h.defaults[3], 13)
    }

    func testAvailabilityExceptionDoesNotSkipOtherRoutes() {
        let h = Harness()
        h.availabilityErrors = [12]
        let failures = h.restore()
        XCTAssertEqual(failures.map(\.selector), [2])
        XCTAssertEqual(failures.map(\.stage), [.availability])
        XCTAssertEqual(failures.map(\.message), ["availability failed"])
        XCTAssertFalse(h.operations.contains("read:2"))
        XCTAssertEqual(h.writes, [1, 3])
    }

    func testInitialReadExceptionDoesNotWriteThatRouteOrSkipOthers() {
        let h = Harness()
        h.readErrors = [1]
        let failures = h.restore()
        XCTAssertEqual(failures.map(\.selector), [1])
        XCTAssertEqual(failures.map(\.stage), [.read])
        XCTAssertEqual(failures.map(\.message), ["read failed"])
        XCTAssertEqual(h.writes, [2, 3])
        XCTAssertEqual(h.defaults[2], 12)
        XCTAssertEqual(h.defaults[3], 13)
    }

    func testWriteExceptionDoesNotSkipOtherRoutes() {
        let h = Harness()
        h.writeErrors = [1]
        let failures = h.restore()
        XCTAssertEqual(failures.map(\.selector), [1])
        XCTAssertEqual(failures.map(\.stage), [.write])
        XCTAssertEqual(failures.map(\.message), ["write failed"])
        XCTAssertEqual(h.writes, [1, 2, 3])
        XCTAssertEqual(h.operations.filter { $0 == "read:1" }.count, 1)
        XCTAssertEqual(h.defaults[1], 91)
        XCTAssertEqual(h.defaults[2], 12)
        XCTAssertEqual(h.defaults[3], 13)
    }

    func testSuccessfulWriteWithMismatchingReadIsFailureAndOtherRoutesRecover() {
        let h = Harness()
        h.ignoredWrites = [1]
        let failures = h.restore()
        XCTAssertEqual(failures.map(\.selector), [1])
        XCTAssertEqual(failures.map(\.stage), [.verification])
        XCTAssertEqual(h.operations.filter { $0 == "read:1" }.count, 2)
        XCTAssertEqual(h.writes, [1, 2, 3])
        XCTAssertEqual(h.defaults[2], 12)
        XCTAssertEqual(h.defaults[3], 13)
    }

    func testVerificationReadExceptionDoesNotSkipOtherRoutes() {
        let h = Harness()
        h.verificationErrors = [1]
        let failures = h.restore()
        XCTAssertEqual(failures.map(\.selector), [1])
        XCTAssertEqual(failures.map(\.stage), [.verification])
        XCTAssertEqual(failures.map(\.message), ["verification read failed"])
        XCTAssertEqual(h.writes, [1, 2, 3])
        XCTAssertEqual(h.defaults[2], 12)
        XCTAssertEqual(h.defaults[3], 13)
    }

    func testFailuresAccumulateInRequestedOrderWithoutStoppingTheLoop() {
        let h = Harness()
        h.unavailable = [13]
        h.writeErrors = [1]
        h.ignoredWrites = [2]
        let failures = h.restore(selectors: [3, 1, 2])
        XCTAssertEqual(failures.map(\.selector), [3, 1, 2])
        XCTAssertEqual(failures.map(\.expectedDevice), [13, 11, 12])
        XCTAssertEqual(failures.map(\.stage), [.availability, .write, .verification])
        XCTAssertEqual(h.writes, [1, 2])
    }

    func testUnlockedSelectorsAndUnrequestedLocksAreUntouched() {
        let h = Harness()
        XCTAssertEqual(h.restore(selectors: [1, 2, 3], locked: [2: 12, 4: 14]), [])
        XCTAssertEqual(h.operations, ["alive:12", "read:2", "write:2:12", "read:2"])
        XCTAssertEqual(h.writes, [2])
    }

    func testNoLocksPerformNoOperations() {
        let h = Harness()
        XCTAssertEqual(h.restore(locked: [:]), [])
        XCTAssertEqual(h.operations, [])
    }
}
