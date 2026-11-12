import XCTest
@testable import MicLinkCore

final class ButtonEventsTests: XCTestCase {
    func status(_ seq: UInt16, power: UInt8 = 0, record: UInt8 = 0xd0, link: UInt8 = 0) -> [UInt8] {
        var c: [UInt8] = [0x55,58,4,0,0x3a,2,UInt8(seq & 255),UInt8(seq >> 8),0,2,0xff]
        c[3] = crc8(Array(c.prefix(3))); c += [UInt8](repeating: 0, count: 45)
        c[20] = link; c[44] = record; c[45] = power
        let sum = crc16(c); return c + [UInt8(sum & 255),UInt8(sum >> 8)]
    }
    func testSeparateStateCorrelationsAndLinkRisingEdge() {
        let d = MicButtonDetector()
        XCTAssertTrue(d.observe(status(1), time: 1).isEmpty)
        XCTAssertEqual(d.observe(status(2, power: 0x20), time: 2).map(\.button), [.power])
        XCTAssertEqual(d.observe(status(3, power: 0x20, record: 0xd1), time: 3).map(\.button), [.record])
        XCTAssertEqual(d.observe(status(4, power: 0x20, record: 0xd1, link: 8), time: 4).map(\.button), [.link])
        XCTAssertTrue(d.observe(status(5, power: 0x20, record: 0xd1), time: 5).isEmpty)
    }
    func testInitialStatusDuplicatesAndLongGapNeverTrigger() {
        let d = MicButtonDetector()
        XCTAssertTrue(d.observe(status(1, power: 0x20, record: 0xd1, link: 8), time: 1).isEmpty)
        XCTAssertTrue(d.observe(status(1), time: 2).isEmpty)
        XCTAssertTrue(d.observe(status(0), time: 2.5).isEmpty)
        XCTAssertTrue(d.observe(status(2), time: 7).isEmpty)
    }
    func testBadChecksumCannotCreateOrChangeBaseline() {
        let d = MicButtonDetector(); _ = d.observe(status(1), time: 1)
        var corrupt = status(2, power: 0x20); corrupt[30] ^= 1
        XCTAssertTrue(d.observe(corrupt, time: 2).isEmpty)
        XCTAssertEqual(d.observe(status(3, power: 0x20), time: 3).map(\.button), [.power])
    }
    func testIdleStatusAndOtherBitsDoNotBecomeKeyEvents() {
        let d = MicButtonDetector(); _ = d.observe(status(1), time: 1)
        XCTAssertTrue(d.observe(status(2, link: 0x10), time: 2).isEmpty)
        XCTAssertTrue(d.observe(status(3, link: 0x10), time: 3).isEmpty)
        XCTAssertTrue(d.observe(status(4, power: 0x01, record: 0xe0, link: 0x10), time: 4).isEmpty)
        XCTAssertEqual(d.observe(status(5, power: 0x21, record: 0xe0, link: 0x10), time: 5).map(\.button), [.power])
        XCTAssertEqual(d.observe(status(6, power: 0x21, record: 0xe1, link: 0x10), time: 6).map(\.button), [.record])
    }
}
