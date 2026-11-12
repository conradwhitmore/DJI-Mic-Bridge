import XCTest
@testable import MicLinkCore

final class BatteryQueryTests: XCTestCase {
    private func reply(percent: UInt8, count: Int = 40, sequence: UInt16 = 123, source: UInt8 = 0x3a) -> [UInt8] {
        var c: [UInt8] = [0x55, UInt8(13 + count), 4, 0, source, 2, UInt8(sequence & 255), UInt8(sequence >> 8), 0x80, 5, 6]
        c[3] = crc8(Array(c.prefix(3)))
        c += [percent] + Array(repeating: 0, count: count - 1)
        let sum = crc16(c); c += [UInt8(sum & 255), UInt8(sum >> 8)]
        return c
    }
    func testBatteryIsDataNotACKStatusIncludingZero() throws {
        let q = try MicControlQuery(command: .battery, sequence: 123)
        for level: UInt8 in [0, 1, 85, 100] {
            let payload = try XCTUnwrap(q.reply(reply(percent: level)))
            XCTAssertEqual(payload[0], level)
            XCTAssertEqual(q.summary(payload), "TX 电量 \(level)%")
        }
        let request = try XCTUnwrap(FrameParser().feed(Data(q.packet)).first?.control)
        XCTAssertEqual(request.count, 13) // Empty request, ACK requested, unchanged route.
        XCTAssertEqual(Array(request[4...5]), [2, 0x3a])
        XCTAssertEqual(Array(request[8...10]), [0x40, 5, 6])
        XCTAssertEqual(MicControlCommand.allCases, [.version, .audioConfiguration, .deviceAddress, .deleteSPPReconnect])
    }
    func testRejectInvalidBatteryRepliesAndIgnoreOtherTransactions() throws {
        let q = try MicControlQuery(command: .battery, sequence: 123)
        XCTAssertThrowsError(try q.reply(reply(percent: 101)))
        XCTAssertThrowsError(try q.reply(reply(percent: 255)))
        XCTAssertThrowsError(try q.reply(reply(percent: 0, count: 1)))
        XCTAssertThrowsError(try q.reply(reply(percent: 85, count: 39)))
        XCTAssertThrowsError(try q.reply(reply(percent: 85, count: 41)))
        XCTAssertNil(try q.reply(reply(percent: 85, sequence: 124)))
        XCTAssertNil(try q.reply(reply(percent: 85, source: 0x1a)))
        var bad = reply(percent: 85); bad[11] ^= 1
        XCTAssertThrowsError(try q.reply(bad))
    }
}
