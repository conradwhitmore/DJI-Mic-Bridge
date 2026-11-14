import XCTest
import Mini2Protocol
import MicLinkCore

final class StatusTests: XCTestCase {
    func testWirelessDenoisePacketUsesReceiverLayout() {
        for enabled in [false, true] {
            let p = mini2DenoisePacket(enabled: enabled)
            XCTAssertEqual(p.count, 129)
            XCTAssertEqual(Array(p.prefix(12)), [0xaa,4,0,0x55,9,0x58,enabled ? 0x2b : 0x2a,0x19,0,0,0x11,enabled ? 1 : 0])
            XCTAssertTrue(p[12..<128].allSatisfy { $0 == 0 })
            XCTAssertEqual(p.last, 0xa5)
        }
    }
    func testConfirmationRejectsEarlyUnstableAndExpiredStates() {
        var p = Mini2DenoiseConfirmation(target: true, sentAt: 10)
        for _ in 0..<5 { XCTAssertFalse(p.observe(true, at: 10.1)) }
        XCTAssertFalse(p.observe(true, at: 10.4))
        XCTAssertFalse(p.observe(false, at: 10.5))
        XCTAssertFalse(p.observe(true, at: 10.6))
        XCTAssertFalse(p.observe(true, at: 10.7))
        XCTAssertTrue(p.observe(true, at: 10.8))
        XCTAssertTrue(p.expired(at: 16))
        XCTAssertFalse(p.observe(true, at: 16))
    }
    private func status(_ capture: UInt8 = 0, denoise: Bool = false) -> [UInt8] {
        var p: [UInt8] = [0x55,0x16,5,5,0x19,0,0,1,0x77,0xac,2,0,0,1,0,5,0,0,0,0,0,0]
        p[12] = capture; p[11] = denoise ? 0x80 : 0
        p[9] = crc8(Array(p[10..<22])); p[3] = UInt8(p[4..<22].reduce(0) { $0 + Int($1) } & 63)
        return p
    }
    private func block(_ side: UInt8, _ sequence: UInt8, type: UInt8 = 0x10) -> Data {
        var b = [UInt8](repeating: 0, count: 125)
        b.replaceSubrange(6..<9, with: [0x55, 0x77, 5]); b[10] = type; b[11] = side; b[12] = sequence
        b[9] = 0x40 | UInt8(b[10..<125].reduce(0) { $0 + Int($1) } & 63)
        return Data(b)
    }
    func testCapturedIdleFixtureAndConsecutiveEventsRemainDistinct() {
        var parser = Mini2StatusParser(), frames: [Mini2SPPStatus] = []
        let stream = [UInt8(0xff), 0x55] + status() + status(1) + status(1) + status(0, denoise: true)
        for (i, byte) in stream.enumerated() { frames += parser.feed(block(byte, UInt8(truncatingIfNeeded: i))) }
        XCTAssertEqual(frames.map(\.capture), [0, 1, 1, 0])
        XCTAssertEqual(frames.map(\.denoise), [false, false, false, true])
        XCTAssertEqual(parser.sequenceGaps, 0)
    }
    func testGapDoesNotSplicePartialEventAndResynchronizes() {
        var parser = Mini2StatusParser(), frames: [Mini2SPPStatus] = []
        let p = status(1)
        for i in 0..<22 where i != 15 { frames += parser.feed(block(p[i], UInt8(i))) }
        for (i, byte) in status().enumerated() { frames += parser.feed(block(byte, UInt8(i + 22))) }
        XCTAssertEqual(frames.map(\.capture), [0]); XCTAssertEqual(parser.sequenceGaps, 1)
    }
    func testDuplicateAudioAndCapabilitySideByte() {
        var parser = Mini2StatusParser(), frames: [Mini2SPPStatus] = []
        var seq: UInt8 = 250
        for (i, byte) in status(1).enumerated() {
            let cap = i == 5
            let b = block(byte, seq, type: cap ? 0x20 : 0x10)
            frames += parser.feed(b)
            if !cap { frames += parser.feed(b); seq &+= 1 }
        }
        XCTAssertEqual(frames.map(\.capture), [1]); XCTAssertEqual(parser.sequenceGaps, 0)
        XCTAssertEqual(parser.duplicateBlocks, 21)
    }
    func testCorruptInnerCRCAndOuterChecksumCannotGenerateEvent() {
        var parser = Mini2StatusParser(), frames: [Mini2SPPStatus] = []
        var bad = status(1); bad[9] ^= 1; bad[3] = UInt8(bad[4..<22].reduce(0) { $0 + Int($1) } & 63)
        for (i, byte) in (bad + status()).enumerated() { frames += parser.feed(block(byte, UInt8(i))) }
        XCTAssertEqual(frames.map(\.capture), [0])
        var corrupt = block(0x55, 44); corrupt[11] ^= 1
        XCTAssertTrue(parser.feed(corrupt).isEmpty); XCTAssertEqual(parser.invalidBlocks, 1)
    }
}
