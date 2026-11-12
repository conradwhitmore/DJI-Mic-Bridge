import XCTest
@testable import MicLinkCore

final class VibrationQueryTests: XCTestCase {
    // Live 04.05.02.31 02/A0 response, including status byte.
    private var snapshot: [UInt8] {
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xd0,0,12,0,0,0xd0,0,12,0,0]
    }
    func testLiveConfigurationChangesOnlyVibration() throws {
        let config = try Mic2AudioConfiguration(reply: snapshot)
        XCTAssertTrue(config.vibrationEnabled)
        let payload = try config.vibrationWritePayload(enabled: false)
        var expected = Array(snapshot.dropFirst()); expected[17] = 0xc0; expected[22] = 0xc0
        XCTAssertEqual(payload, expected)
        var readback = snapshot; readback[18] = 0xc0; readback[23] = 0xc0
        let off = try Mic2AudioConfiguration(reply: readback)
        XCTAssertTrue(off.matches(config, vibrationEnabled: false))
        XCTAssertEqual(try off.vibrationWritePayload(enabled: true), Array(snapshot.dropFirst()))
        readback[20] = 13; readback[25] = 13
        XCTAssertFalse(try Mic2AudioConfiguration(reply: readback).matches(config, vibrationEnabled: false))
    }
    func testNeverEchoesFormatStatusAndPreservesOtherSettings() throws {
        var data = snapshot
        data[18] = 0xfa; data[23] = 0xfa // LED, mute, auto record, record key, lowcut, vibration
        data[19] = 0xf0; data[24] = 0xf0 // denoise/HDR plus read-only status bits
        let payload = try Mic2AudioConfiguration(reply: data).vibrationWritePayload(enabled: false)
        XCTAssertEqual(payload[17], 0xea)
        XCTAssertEqual(payload[18], 0x30)
        XCTAssertEqual(payload[18] & 0x40, 0) // FORMAT action must never be set
        XCTAssertEqual(payload[19], 12)
        XCTAssertEqual(payload[23], 0x30)
    }
    func testRejectsMissingMalformedAndRecordingConfiguration() throws {
        XCTAssertThrowsError(try MicControlQuery(command: .vibrationOff, sequence: 1))
        for index in [0, 1, 17, 21, 22, 26, 27] {
            var bad = snapshot; bad[index] = 1
            XCTAssertThrowsError(try Mic2AudioConfiguration(reply: bad))
        }
        XCTAssertThrowsError(try Mic2AudioConfiguration(reply: Array(snapshot.dropLast())))
        var recording = snapshot; recording[18] |= 1; recording[23] |= 1
        let config = try Mic2AudioConfiguration(reply: recording)
        XCTAssertThrowsError(try config.vibrationWritePayload(enabled: false))
    }
    func testWritePacketUses9FAndChecksACK() throws {
        let q = try MicControlQuery(command: .vibrationOff, sequence: 123,
                                    audioConfiguration: Mic2AudioConfiguration(reply: snapshot))
        let c = try XCTUnwrap(FrameParser().feed(Data(q.packet)).first?.control)
        XCTAssertEqual(c.count, 40)
        XCTAssertEqual(Array(c[8...10]), [0x40, 2, 0x9f])
        XCTAssertEqual(c[11 + 17], 0xc0)
        XCTAssertEqual(c[11 + 18] & 0x40, 0)
        func reply(_ status: UInt8, seq: UInt8 = 123) -> [UInt8] {
            var r: [UInt8] = [0x55,14,4,0,0x3a,2,seq,0,0x80,2,0x9f,status]
            r[3] = crc8(Array(r.prefix(3)))
            let sum = crc16(r); r += [UInt8(sum & 255),UInt8(sum >> 8)]
            return r
        }
        XCTAssertEqual(try q.reply(reply(0)), [0])
        XCTAssertThrowsError(try q.reply(reply(0xff)))
        XCTAssertNil(try q.reply(reply(0, seq: 124)))
    }
}
