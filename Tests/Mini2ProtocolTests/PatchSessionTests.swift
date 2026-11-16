import XCTest
import Mini2Protocol
import MicLinkCore

final class PatchSessionTests: XCTestCase {
    private func reply(_ seq: UInt16, mode: UInt8, caps: UInt16 = 0x1f, revision: UInt16 = 2) -> Mini2Frame {
        var b: [UInt8] = [0x55, 24, 4, 0, 0x3a, 2, UInt8(truncatingIfNeeded: seq), UInt8(seq >> 8), 0x80, 0x3f, 0xf0,
            0x4d, 0x42, 0x52, 0x47, 1, UInt8(truncatingIfNeeded: revision), UInt8(revision >> 8),
            UInt8(truncatingIfNeeded: caps), UInt8(caps >> 8), mode, mode == 2 ? 2 : 0]
        b[3] = crc8(Array(b.prefix(3))); let crc = crc16(b); b += [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
        return Mini2Frame(b)!
    }
    func testFreshIdentityRequiredAndR1NeverEnablesFourKeys() {
        var session = Mini2PatchSession()
        XCTAssertFalse(session.accepts(.connection))
        XCTAssertNotNil(session.next(desired: true, sequence: 1, now: 0))
        XCTAssertEqual(session.pending, .patchIdentity)
        XCTAssertFalse(session.receive(reply(2, mode: 1)))
        XCTAssertTrue(session.receive(reply(1, mode: 0, caps: 0x0f, revision: 1)))
        XCTAssertFalse(session.advancedAvailable)
        XCTAssertNil(session.next(desired: true, sequence: 2, now: 1))
    }
    func testFourKeysOnlyAfterEnableACKAndStopBeforeDisableACK() {
        var session = Mini2PatchSession()
        _ = session.next(desired: true, sequence: 1, now: 0)
        XCTAssertTrue(session.receive(reply(1, mode: 0)))
        _ = session.next(desired: true, sequence: 2, now: 1)
        XCTAssertEqual(session.pending, .patchEnable)
        XCTAssertTrue(session.mayBeEnabled)
        XCTAssertFalse(session.allowsStockEvents)
        XCTAssertFalse(session.accepts(.powerSingle))
        XCTAssertTrue(session.receive(reply(2, mode: 1)))
        for key in Mini2Hotkey.allCases { XCTAssertTrue(session.accepts(key)) }
        _ = session.next(desired: false, sequence: 3, now: 2)
        XCTAssertFalse(session.accepts(.connectionDouble))
        XCTAssertFalse(session.allowsStockEvents)
        XCTAssertTrue(session.receive(reply(3, mode: 0)))
        XCTAssertFalse(session.mayBeEnabled)
        XCTAssertTrue(session.allowsStockEvents)
    }
    func testTimeoutDoesNotFallBackToStockOrRepeatModeWrite() {
        var session = Mini2PatchSession()
        _ = session.next(desired: true, sequence: 1, now: 0); _ = session.receive(reply(1, mode: 0))
        _ = session.next(desired: true, sequence: 2, now: 1)
        XCTAssertNil(session.next(desired: true, sequence: 3, now: 6))
        XCTAssertNotNil(session.error); XCTAssertTrue(session.mayBeEnabled)
        XCTAssertFalse(session.allowsStockEvents); XCTAssertFalse(session.accepts(.connection))
        XCTAssertFalse(session.receive(reply(2, mode: 1))) // Late ACK cannot enable shortcuts.
        XCTAssertNil(session.next(desired: true, sequence: 4, now: 9))
        session.retry()
        XCTAssertNotNil(session.next(desired: false, closing: true, sequence: 5, now: 10))
        XCTAssertEqual(session.pending, .patchDisable)
        XCTAssertTrue(session.receive(reply(5, mode: 0))); XCTAssertFalse(session.mayBeEnabled)
    }
    func testBoundedReadOnlyProbesAndNoWritesToUnknownDeviceAtQuit() {
        var session = Mini2PatchSession()
        for i in 0..<3 {
            XCTAssertNotNil(session.next(desired: true, sequence: UInt16(i + 1), now: Double(i * 6)))
            XCTAssertEqual(session.pending, .patchIdentity)
            XCTAssertNil(session.next(desired: true, sequence: 100, now: Double(i * 6 + 4)))
        }
        XCTAssertTrue(session.allowsStockEvents)
        XCTAssertNil(session.next(desired: true, sequence: 4, now: 30))
        XCTAssertNil(session.next(desired: false, closing: true, sequence: 5, now: 31))
        let reconnect = Mini2PatchSession()
        XCTAssertNil(reconnect.identity); XCTAssertFalse(reconnect.accepts(.connection))
    }
    func testClosingRecoversPreviouslyEnabledSessionEvenWithoutOptIn() {
        var session = Mini2PatchSession()
        _ = session.next(desired: false, sequence: 1, now: 0); _ = session.receive(reply(1, mode: 1))
        XCTAssertTrue(session.mayBeEnabled)
        _ = session.next(desired: false, closing: true, sequence: 2, now: 1)
        XCTAssertEqual(session.pending, .patchDisable)
        _ = session.receive(reply(2, mode: 0))
        XCTAssertNil(session.next(desired: false, closing: true, sequence: 3, now: 2))
    }
    func testQuitDoesNotReenableRememberedMappingAfterDisableACK() {
        var session = Mini2PatchSession()
        _ = session.next(desired: true, sequence: 1, now: 0)
        _ = session.receive(reply(1, mode: 0))
        _ = session.next(desired: true, sequence: 2, now: 1)
        _ = session.receive(reply(2, mode: 1))
        session.retry()
        _ = session.next(desired: true, closing: true, sequence: 3, now: 2)
        XCTAssertEqual(session.pending, .patchDisable)
        _ = session.receive(reply(3, mode: 0))
        XCTAssertNil(session.next(desired: true, closing: true, sequence: 4, now: 3))
        XCTAssertFalse(session.mayBeEnabled)
    }

}
