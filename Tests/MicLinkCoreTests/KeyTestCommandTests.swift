import XCTest
@testable import MicLinkCore

final class KeyTestCommandTests: XCTestCase {
    private func frame(_ payload: [UInt8], sequence: UInt16 = 123, flags: UInt8 = 0x80,
                       source: UInt8 = 0x3a, destination: UInt8 = 2) -> [UInt8] {
        var c: [UInt8] = [0x55, UInt8(13 + payload.count), 4, 0, source, destination,
                         UInt8(sequence & 255), UInt8(sequence >> 8), flags, 4, 0x68] + payload
        c[3] = crc8(Array(c.prefix(3)))
        let sum = crc16(c); c += [UInt8(sum & 255), UInt8(sum >> 8)]
        return c
    }
    func testFixedEnterAndExitPacketsAndMatchingACK() throws {
        for (command, mode): (MicControlCommand, UInt8) in [(.keyTestOn, 1), (.keyTestOff, 0)] {
            let q = try MicControlQuery(command: command, sequence: 123)
            let c = try XCTUnwrap(FrameParser().feed(Data(q.packet)).first?.control)
            XCTAssertEqual(Array(c[9..<14]), [4, 0x68, 0x43, 1, mode])
            XCTAssertEqual(try q.reply(frame([0, 0x43, 1, mode])), [0, 0x43, 1, mode])
            XCTAssertThrowsError(try q.reply(frame([0, 0x43, 1, mode ^ 1])))
            XCTAssertThrowsError(try q.reply(frame([0xff, 0x43, 1, mode])))
            XCTAssertThrowsError(try q.reply(frame([0])))
            XCTAssertNil(try q.reply(frame([0, 0x43, 1, mode], sequence: 124)))
            XCTAssertNil(try q.reply(frame([0x43, 1, 2], flags: 0)))
        }
        XCTAssertFalse(MicControlCommand.allCases.contains(.keyTestOn))
        XCTAssertFalse(MicControlCommand.allCases.contains(.keyTestOff))
    }
    func testIndependentEventsDoNotRequireRecordingOrDenoiseStateChange() {
        for (id, button): (UInt8, MicButton) in [(1, .power), (2, .record), (3, .link)] {
            let event = MicKeyTestEvent(frame: frame([0x43, 1, id], flags: 0))
            XCTAssertEqual(event?.button, button)
            XCTAssertEqual(event?.sequence, 123)
        }
    }
    func testRejectsACKWrongRouteMalformedOrUnknownEvents() {
        XCTAssertNil(MicKeyTestEvent(frame: frame([0, 0x43, 1, 1])))
        XCTAssertNil(MicKeyTestEvent(frame: frame([0x43, 1, 2], flags: 0x80)))
        XCTAssertNil(MicKeyTestEvent(frame: frame([0x43, 1, 2], flags: 0, destination: 3)))
        XCTAssertNil(MicKeyTestEvent(frame: frame([0x43, 1, 0], flags: 0)))
        XCTAssertNil(MicKeyTestEvent(frame: frame([0x44, 1, 2], flags: 0)))
        var bad = frame([0x43, 1, 2], flags: 0); bad[13] = 3
        XCTAssertNil(MicKeyTestEvent(frame: bad))
        XCTAssertNil(MicKeyTestEvent(frame: []))
    }
}
