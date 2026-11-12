import XCTest
@testable import MicLinkCore

final class DenoiseQueryTests: XCTestCase {
    private var snapshot: [UInt8] {
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xd0,0,12,0,0,0xd0,0,12,0,0]
    }
    func testLiveSnapshotOnOffAndReadback() throws {
        let off = try Mic2AudioConfiguration(reply: snapshot)
        XCTAssertFalse(off.denoiseEnabled)
        var expected = Array(snapshot.dropFirst())
        expected[18] = 0x10; expected[23] = 0x10
        XCTAssertEqual(try off.denoiseWritePayload(enabled: true), expected)
        var reply = snapshot; reply[19] = 0x10; reply[24] = 0x10
        let on = try Mic2AudioConfiguration(reply: reply)
        XCTAssertTrue(on.denoiseEnabled)
        XCTAssertTrue(on.matches(off, denoiseEnabled: true))
        XCTAssertEqual(try on.denoiseWritePayload(enabled: false), Array(snapshot.dropFirst()))
        reply[18] ^= 0x10; reply[23] ^= 0x10
        XCTAssertFalse(try Mic2AudioConfiguration(reply: reply).matches(off, denoiseEnabled: true))
    }
    func testPreservesSettingsAndNeverWritesFormatOrRecording() throws {
        var reply = snapshot
        reply[18] = 0xfa; reply[23] = 0xfa
        reply[19] = 0xe0; reply[24] = 0xe0
        let config = try Mic2AudioConfiguration(reply: reply)
        let payload = try config.denoiseWritePayload(enabled: true)
        XCTAssertEqual(payload[17], 0xfa)
        XCTAssertEqual(payload[18], 0x30)
        XCTAssertEqual(payload[19], 12)
        XCTAssertEqual(Array(payload[17..<22]), Array(payload[22..<27]))
        reply[18] |= 1; reply[23] |= 1
        XCTAssertThrowsError(try Mic2AudioConfiguration(reply: reply).denoiseWritePayload(enabled: true))
        XCTAssertThrowsError(try MicControlQuery(command: .denoiseOn, sequence: 42))
    }
    func testWritePacketAndACKRouting() throws {
        let query = try MicControlQuery(command: .denoiseOn, sequence: 42,
            audioConfiguration: Mic2AudioConfiguration(reply: snapshot))
        let c = try XCTUnwrap(FrameParser().feed(Data(query.packet)).first?.control)
        XCTAssertEqual(Array(c[8...10]), [0x40,2,0x9f])
        XCTAssertEqual(c[11 + 18], 0x10)
        func reply(_ status: UInt8, seq: UInt8 = 42) -> [UInt8] {
            var r: [UInt8] = [0x55,14,4,0,0x3a,2,seq,0,0x80,2,0x9f,status]
            r[3] = crc8(Array(r.prefix(3)))
            let sum = crc16(r); r += [UInt8(sum & 255),UInt8(sum >> 8)]
            return r
        }
        XCTAssertEqual(try query.reply(reply(0)), [0])
        XCTAssertThrowsError(try query.reply(reply(1)))
        XCTAssertNil(try query.reply(reply(0, seq: 43)))
    }
}
