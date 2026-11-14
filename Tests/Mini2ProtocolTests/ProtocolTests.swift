import XCTest
import Mini2Protocol
import MicLinkCore

final class Mini2ProtocolTests: XCTestCase {
    func testExplicitSPPExitRequiresMatchingSuccessfulACK() throws {
        let query = try MicControlQuery(command: .deleteSPPReconnect, sequence: 42,
                                        peerAddress: "02:11:22:33:44:55")
        var parser = Mini2SPPParser()
        let request = try XCTUnwrap(parser.feed(Data(query.packet)).first?.control)
        XCTAssertEqual(request.commandSet, 0x12); XCTAssertEqual(request.commandID, 0x65)
        XCTAssertEqual(request.payload, [1, 0x55, 0x44, 0x33, 0x22, 0x11, 2])
        let good = frame(set: 0x12, id: 0x65, payload: [0])
        XCTAssertEqual(try query.reply(good), [0])
        let other = try MicControlQuery(command: .deleteSPPReconnect, sequence: 43,
                                        peerAddress: "02:11:22:33:44:55")
        XCTAssertNil(try other.reply(good))
        XCTAssertThrowsError(try query.reply(frame(set: 0x12, id: 0x65, payload: [1])))
        XCTAssertThrowsError(try query.reply(frame(set: 0x12, id: 0x65, payload: [0, 1])))
        var corrupt = good; corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try query.reply(corrupt))
    }
    func testSPPProbeIsFramedAndWhitelisted() throws {
        for command in Mini2SPPCommand.allCases {
            var parser = Mini2SPPParser()
            let request = command.packet(sequence: 0x2345)
            let result = parser.feed(Data(request))
            let packet = try XCTUnwrap(result.first?.control)
            XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.blocks.count, 0)
            XCTAssertEqual(packet.sequence, 0x2345)
            XCTAssertEqual(packet.commandSet, command.code.0); XCTAssertEqual(packet.commandID, command.code.1)
            XCTAssertNotEqual(packet.commandID, 0x65)
            XCTAssertEqual(packet.payload, command == .clockStart ? [1] : command == .clockStop ? [2] : [])
        }
        let reply = try XCTUnwrap(Mini2Frame(frame(set: 0x12, id: 0x58, payload: [0, 1])))
        XCTAssertTrue(Mini2SPPCommand.clockStart.matches(reply, sequence: 42))
        XCTAssertFalse(Mini2SPPCommand.clockStart.matches(reply, sequence: 43))
    }
    func testAudioExtractionValidatesChecksumTypeAndTrailer() throws {
        var b = [UInt8](repeating: 0, count: 125)
        b.replaceSubrange(6..<9, with: [0x55, 0x77, 5]); b[9] = 0x40; b[10] = 0x10; b[12] = 250
        b.replaceSubrange(13..<124, with: (0..<111).map(UInt8.init))
        b[9] |= UInt8(b[10..<125].reduce(0, { $0 + Int($1) }) & 63)
        XCTAssertEqual(mini2AudioPayload(Data(b)), Data(b[13..<124]))
        var bad = b; bad[13] ^= 1; XCTAssertNil(mini2AudioPayload(Data(bad)))
        bad = b; bad[124] = 1; XCTAssertNil(mini2AudioPayload(Data(bad)))
        bad = b; bad[9] ^= 0x40; XCTAssertNil(mini2AudioPayload(Data(bad)))
        XCTAssertNil(mini2AudioPayload(Data(b.dropLast())))
    }
    private func frame(set: UInt8 = 4, id: UInt8 = 0x68, payload: [UInt8], sequence: UInt16 = 42,
                       source: UInt8 = 0x3a, destination: UInt8 = 2, flags: UInt8 = 0x80) -> [UInt8] {
        let count = 13 + payload.count
        var b: [UInt8] = [0x55, UInt8(count & 255), 4 | UInt8(count >> 8), 0, source, destination,
                          UInt8(sequence & 255), UInt8(sequence >> 8), flags, set, id]
        b[3] = crc8(Array(b.prefix(3))); b += payload
        let crc = crc16(b); return b + [UInt8(crc & 255), UInt8(crc >> 8)]
    }
    func testMini2CommandsAreRawDUMLAndDoNotUseMic2ModeParameters() throws {
        for (command, payload) in [(Mini2Command.keyEnter, [UInt8(0x43), 1, 0]), (.keyExit, [0x43, 1, 8])] {
            let request = Mini2Request(command, sequence: 0x1234)
            let decoded = try XCTUnwrap(Mini2Frame(request.packet))
            XCTAssertEqual(decoded.bytes.first, 0x55)
            XCTAssertEqual(decoded.payload, payload)
            XCTAssertEqual(decoded.source, 2); XCTAssertEqual(decoded.destination, 0x3a)
            XCTAssertEqual(decoded.sequence, 0x1234); XCTAssertEqual(decoded.flags, 0x40)
        }
    }
    func testEveryNotificationSplitAndCoalescedPackets() {
        let a = frame(payload: [0, 0x43, 1, 6], sequence: 0)
        let b = frame(payload: [0, 0x43, 1, 7], sequence: 0)
        for split in 0...(a.count + b.count) {
            var parser = Mini2DUMLParser(); let stream = a + b
            let results = parser.feed(Data(stream.prefix(split))) + parser.feed(Data(stream.dropFirst(split)))
            XCTAssertEqual(results.compactMap(\.independentKey), [6, 7])
        }
    }
    func testSameZeroSequenceReportsAreNotDroppedAndAckIsNotAKey() throws {
        var parser = Mini2DUMLParser()
        let key = frame(payload: [0, 0x43, 1, 6], sequence: 0, destination: 0x0a)
        XCTAssertEqual(parser.feed(Data(key + key)).compactMap(\.independentKey), [6, 6])
        for value: UInt8 in [0, 8] { XCTAssertNil(Mini2Frame(frame(payload: [0, 0x43, 1, value]))?.independentKey) }
        XCTAssertNil(Mini2Frame(frame(payload: [0, 0x43, 1, 6], source: 0x5a))?.independentKey)
        XCTAssertNil(Mini2Frame(frame(payload: [0, 0x43, 1, 6], flags: 0))?.independentKey)
        let request = Mini2Request(.keyEnter, sequence: 42)
        let keySameSequence = try XCTUnwrap(Mini2Frame(frame(payload: [0, 0x43, 1, 6])))
        XCTAssertFalse(request.matches(keySameSequence))
    }
    func testCRCFailureAndJunkResynchronize() {
        let good = frame(payload: [0, 0x43, 1, 7])
        var bad = good; bad[14] ^= 1
        XCTAssertNil(Mini2Frame(bad))
        var parser = Mini2DUMLParser()
        let found = parser.feed(Data([0xff, 0x55, 0, 0] + bad + good))
        XCTAssertEqual(found.compactMap(\.independentKey), [7]); XCTAssertGreaterThan(parser.discardedBytes, 0)
    }
    func testReplyRequiresAddressCommandSequenceAndExactModeEcho() throws {
        let request = Mini2Request(.keyExit, sequence: 42)
        let right = try XCTUnwrap(Mini2Frame(frame(payload: [0, 0x43, 1, 8])))
        XCTAssertEqual(try request.validate(right), [0, 0x43, 1, 8])
        for bytes in [frame(payload: [0, 0x43, 1, 8], sequence: 41),
                      frame(payload: [0, 0x43, 1, 8], destination: 0x0a),
                      frame(set: 5, payload: [0, 0x43, 1, 8])] {
            XCTAssertFalse(request.matches(try XCTUnwrap(Mini2Frame(bytes))))
        }
        XCTAssertThrowsError(try request.validate(XCTUnwrap(Mini2Frame(frame(payload: [0, 0x43, 1, 0])))))
        XCTAssertThrowsError(try request.validate(XCTUnwrap(Mini2Frame(frame(payload: [1])))))
    }
    func testVersionAndBatteryHaveDifferentPayloadSemantics() throws {
        var p = [UInt8](repeating: 0, count: 30)
        p.replaceSubrange(2..<17, with: Array("DJI MIC MINI TX".utf8))
        p.replaceSubrange(22..<26, with: [0, 17, 3, 2])
        XCTAssertEqual(Mini2Request.version(p), "02.03.17.00")
        XCTAssertEqual(Mini2Request.product(p), "DJI MIC MINI TX")
        let v = try XCTUnwrap(Mini2Frame(frame(set: 0, id: 1, payload: p)))
        XCTAssertEqual(try Mini2Request(.version, sequence: 42).validate(v).count, 30)
        var battery = [UInt8](repeating: 0, count: 40); battery[0] = 60; battery[1] = 0x74; battery[2] = 0x0e
        let b = try XCTUnwrap(Mini2Frame(frame(set: 5, id: 6, payload: battery)))
        XCTAssertEqual(try Mini2Request(.battery, sequence: 42).validate(b).first, 60)
    }
    func testSPPVariableBlockCountLongControlAnd112ByteTail() throws {
        let control = frame(set: 0x5b, id: 3, payload: [UInt8](repeating: 0x12, count: 260))
        var block = [UInt8](repeating: 0, count: 125)
        block.replaceSubrange(6..<9, with: [0x55, 0x77, 5]); block[124] = 0xcd
        let descriptor = UInt8(2 << 2) | UInt8(control.count >> 8)
        var raw: [UInt8] = [0xaa, descriptor, UInt8(control.count & 255)]
        raw.append(contentsOf: block)
        raw.append(contentsOf: block)
        raw.append(contentsOf: control)
        raw.append(0xa5)
        for split in [1, 2, 3, 127, 253, raw.count - 1] {
            var parser = Mini2SPPParser()
            let result = parser.feed(Data(raw.prefix(split))) + parser.feed(Data(raw.dropFirst(split)))
            let packet = try XCTUnwrap(result.first)
            XCTAssertEqual(result.count, 1); XCTAssertEqual(packet.blocks.count, 2)
            XCTAssertEqual(packet.blocks[0].last, 0xcd); XCTAssertEqual(packet.control?.payload.count, 260)
        }
    }
    func testSPPRejectsBadFooterAndCRCButKeepsLaterEnvelope() {
        let control = frame(payload: [0, 0x43, 1, 7])
        let good: [UInt8] = [0xaa, 0, UInt8(control.count)] + control + [0xa5]
        var bad = good; bad[bad.count - 1] = 0
        var parser = Mini2SPPParser()
        XCTAssertEqual(parser.feed(Data(bad + good)).count, 1)
    }
}
