import XCTest
import Mini2Protocol
import MicLinkCore

final class SPPStreamTests: XCTestCase {
    private func snapshot(capture: UInt8 = 0, nc: Bool = false, battery: UInt8 = 1) -> [UInt8] {
        var p: [UInt8] = [0x55,0x16,5,5,0x19,0,0,1,0x77,0xac,2,0,0,1,0,5,0,0,0,0,0,0]
        p[12] = capture; p[11] = nc ? 0x80 : 0
        p[13] = battery
        p[9] = crc8(Array(p[10...])); p[3] = UInt8(p[4...].reduce(0) { $0 + Int($1) } & 63)
        return p
    }
    private func packet(_ side: UInt8, seq: UInt8) -> Data {
        var block = [UInt8](repeating: 0, count: 125)
        block.replaceSubrange(6..<9, with: [0x55,0x77,5]); block[10] = 0x10; block[11] = side; block[12] = seq
        block[9] = 0x40 | UInt8(block[10...].reduce(0) { $0 + Int($1) } & 63)
        return Data([0xaa,4,0] + block + [0xa5])
    }
    func testFragmentedStreamYieldsBothHotkeysAndOnly111ByteAudio() {
        var receiver = Mini2SPPStream(), events: [Mini2Hotkey] = [], audio = 0
        let states = snapshot() + snapshot(capture: 1) + snapshot(nc: true) + snapshot(nc: true) + snapshot(nc: false)
        for (i, byte) in states.enumerated() {
            let p = packet(byte, seq: UInt8(i))
            for fragment in [p.prefix(17), p.dropFirst(17)] {
                let batch = receiver.feed(Data(fragment), at: Double(i) * 0.005)
                events += batch.events; audio += batch.audio.count
                XCTAssertTrue(batch.audio.allSatisfy { $0.count == 111 })
            }
        }
        XCTAssertEqual(events, [.connection, .powerDouble, .powerDouble])
        XCTAssertEqual(audio, 110); XCTAssertEqual(receiver.statusCount, 5)
        XCTAssertEqual(receiver.sequenceGaps, 0)
    }
    func testLossResynchronizesWithoutCreatingPowerHotkeyAndDuplicatesDoNotReplay() {
        var receiver = Mini2SPPStream(), events: [Mini2Hotkey] = []
        var seq: UInt8 = 0
        for bytes in [snapshot(), snapshot(nc: true), snapshot(capture: 1, nc: true)] {
            if seq == 22 { seq &+= 1 }
            for byte in bytes {
                let p = packet(byte, seq: seq); seq &+= 1
                events += receiver.feed(p, at: Double(seq) * 0.005).events
                let duplicate = receiver.feed(p, at: Double(seq) * 0.005)
                XCTAssertTrue(duplicate.events.isEmpty); XCTAssertTrue(duplicate.audio.isEmpty)
            }
        }
        XCTAssertEqual(events, [.connection]); XCTAssertEqual(receiver.sequenceGaps, 1)
    }
    func testValidatedExitReplyReachesControlPathWithoutAudioOrKeys() throws {
        let request = try MicControlQuery(command: .deleteSPPReconnect, sequence: 42, peerAddress: "02:11:22:33:44:55")
        var reply: [UInt8] = [0x55,14,4,0,0x3a,2,42,0,0x80,0x12,0x65,0]
        reply[3] = crc8(Array(reply.prefix(3)))
        let checksum = crc16(reply); reply += [UInt8(checksum & 255),UInt8(checksum >> 8)]
        var receiver = Mini2SPPStream()
        let batch = receiver.feed(Data([0xaa,0,14] + reply + [0xa5]), at: 0)
        XCTAssertEqual(batch.controls.count, 1)
        XCTAssertEqual(try request.reply(batch.controls[0].bytes), [0])
        XCTAssertTrue(batch.audio.isEmpty); XCTAssertTrue(batch.events.isEmpty)
    }

    func testBatteryBandsThroughValidatedStreamDoNotTriggerHotkeys() throws {
        var receiver = Mini2SPPStream()
        let bands: [(UInt8, ClosedRange<Int>?, Int?)] = [
            (1, 81...100, 90), (2, 61...80, 70), (3, 41...60, 50),
            (4, 21...40, 30), (5, 11...20, 15), (6, 4...10, 7), (7, 0...3, 2),
            (0, nil, nil), (8, nil, nil), (255, nil, nil)
        ]
        var seq: UInt8 = 0
        for (band, range, estimate) in bands {
            var statuses: [Mini2SPPStatus] = []
            for byte in snapshot(battery: band) {
                let batch = receiver.feed(packet(byte, seq: seq), at: Double(seq) * 0.005)
                seq &+= 1; statuses += batch.statuses
                XCTAssertTrue(batch.events.isEmpty)
            }
            let status = try XCTUnwrap(statuses.first)
            XCTAssertEqual(statuses.count, 1)
            XCTAssertEqual(status.batteryLevel?.percentRange, range)
            XCTAssertEqual(status.batteryLevel?.estimatedPercent, estimate)
        }
    }
}
