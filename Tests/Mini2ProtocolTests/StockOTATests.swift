import XCTest
@testable import Mini2Protocol

final class StockOTATests: XCTestCase {
    private func ready(_ image: Data, mtu: Int = 244) throws -> Mini2OTAHost {
        var h = Mini2OTAHost(image: image, maximumPacket: mtu)
        XCTAssertEqual(try h.start().data, Data([9,1,128,11,0,9,1,0,1,10,4,0,0,0,0,0]))
        _ = try h.receive(OTAFrame(1, OTAFrame.tlv(0x7f, 100_000, size: 4) + OTAFrame.tlv(9, 1, size: 1)))
        _ = try h.receive(OTAFrame(2, OTAFrame.tlv(3, 256, size: 2) + OTAFrame.tlv(4, 0, size: 2) + OTAFrame.tlv(5, 0, size: 1)))
        return h
    }
    private func read(_ offset: UInt32, _ n: UInt32) -> OTAFrame {
        OTAFrame(3, OTAFrame.tlv(1, offset, size: 4) + OTAFrame.tlv(2, n, size: 4) + OTAFrame.tlv(3, 0, size: 1))
    }
    func testFragmentedAndCoalescedNotifications() throws {
        let frames = [OTAFrame(1, OTAFrame.tlv(0x7f, 100_000, size: 4)), read(0, 1024)]
        let wire = frames.reduce(Data()) { $0 + $1.data }
        for split in 0...wire.count {
            var p = OTAParser()
            let a = try p.feed(wire.prefix(split)), b = try p.feed(wire.dropFirst(split))
            XCTAssertEqual(a + b, frames)
        }
        var p = OTAParser(); XCTAssertThrowsError(try p.feed(Data([0x55,1,128,0,0])))
        XCTAssertThrowsError(try OTAFrame(1, [1,4,0,2]).fields())
        XCTAssertThrowsError(try OTAFrame(1, [1,0,0,1,0,0]).fields())
    }
    func testDeviceRangesCRCSequenceWrapAndRetry() throws {
        let image = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0) })
        var h = try ready(image)
        let packets = try h.receive(read(17, 66_000))
        XCTAssertGreaterThan(packets.count, 256)
        var actual = Data()
        for (i, packet) in packets.enumerated() {
            XCTAssertEqual(packet.command, 11); XCTAssertEqual(packet.payload[0], UInt8(truncatingIfNeeded: i))
            XCTAssertLessThanOrEqual(packet.data.count, 244)
            let b = Array(packet.payload.dropFirst(5))
            XCTAssertEqual(OTAFrame.uint(packet.payload, at: 1, size: 4), OTAFrame.crc32(b))
            actual.append(contentsOf: b)
        }
        XCTAssertEqual(actual, image.subdata(in: 17..<66_017))
        XCTAssertEqual(try h.receive(read(17, 66_000)), packets)
        XCTAssertThrowsError(try h.receive(read(UInt32.max, 10)))
        XCTAssertThrowsError(try h.receive(read(69_999, 2)))
        XCTAssertEqual(h.phase, .transfer)
        XCTAssertEqual(try h.receive(OTAFrame(6, [1,1,0,1])), [OTAFrame(6)])
        XCTAssertEqual(h.phase, .validated)
        XCTAssertThrowsError(try h.receive(read(0, 1)))
        XCTAssertEqual(OTAFrame.crc32(Array("123456789".utf8)), 0xcbf43926)
    }
    func testFailureAndSmallATT() throws {
        var h = try ready(Data(repeating: 0x7a, count: 1024), mtu: 20)
        XCTAssertTrue(try h.receive(read(0, 1024)).allSatisfy { $0.data.count <= 20 })
        _ = try h.receive(OTAFrame(6, [1,1,0,0])); XCTAssertEqual(h.phase, .rejected)
        var h2 = Mini2OTAHost(image: Data([1]), maximumPacket: 244)
        _ = try h2.start()
        XCTAssertThrowsError(try h2.receive(read(0, 1)))
        XCTAssertThrowsError(try h2.receive(OTAFrame(1, OTAFrame.tlv(0x7f, 100_010, size: 4))))
        XCTAssertEqual(h2.phase, .rejected)
        XCTAssertThrowsError(try Mini2StockImage(package: Data(repeating: 0, count: 1_463_978)))
    }
    func testOfficialPackageWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MINI2_OFFICIAL_PACKAGE"] else { throw XCTSkip("Local official package is not distributed with tests") }
        let original = try Data(contentsOf: URL(fileURLWithPath: path)), tx = try Mini2StockImage(package: original)
        XCTAssertEqual(tx.bytes.count, 724_992)
        var changed = original; changed[4096] ^= 1
        XCTAssertThrowsError(try Mini2StockImage(package: changed))
    }
}
