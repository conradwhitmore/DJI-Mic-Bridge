import XCTest
@testable import MicLinkCore

final class StreamTests: XCTestCase {
    func control(sequence: UInt16, pressed: Bool) -> [UInt8] {
        var c: [UInt8] = [0x55,58,4,0,0x3a,2,UInt8(sequence & 255),UInt8(sequence >> 8),0,2,0xff]
        c[3] = crc8(Array(c.prefix(3)))
        c += [UInt8](repeating: 0, count: 45); c[20] = pressed ? 8 : 0
        let sum = crc16(c); c += [UInt8(sum & 255),UInt8(sum >> 8)]
        return c
    }
    func audio(first: UInt8) -> Data {
        var result: [UInt8] = [0xaa,0x14,0]
        for i in 0..<5 {
            var block = [UInt8](repeating: 0, count: 125)
            block[6] = 0x55; block[7] = 0x77; block[8] = 5; block[12] = first &+ UInt8(i)
            result += block
        }
        return Data(result + [0xa5])
    }
    func testFragmentationAndSequenceWrap() throws {
        let stream = audio(first: 253) + audio(first: 2), parser = FrameParser()
        var frames = 0
        for byte in stream { frames += try parser.feed(Data([byte])).reduce(0) { $0 + $1.audio.count } }
        XCTAssertEqual(frames, 10); XCTAssertEqual(parser.pendingBytes, 0)
    }
    func testGapCorruptionAndOversizeAreRejected() throws {
        let parser = FrameParser(); _ = try parser.feed(audio(first: 0))
        XCTAssertThrowsError(try parser.feed(audio(first: 6)))
        var bad = audio(first: 0); bad[9] = 0
        XCTAssertThrowsError(try FrameParser().feed(bad))
        XCTAssertThrowsError(try FrameParser().feed(Data(repeating: 0, count: 1_048_577)))
    }
    func testTolerantSequenceGapsPreserveFramesAcrossFragmentation() throws {
        let parser = FrameParser(requireContinuousAudio: false)
        let stream = audio(first: 253) + audio(first: 3) + audio(first: 3) + audio(first: 8)
        var frames = 0
        for byte in stream {
            frames += try parser.feed(Data([byte])).reduce(0) { $0 + $1.audio.count }
        }
        XCTAssertEqual(frames, 20)
        XCTAssertEqual(parser.audioDiscontinuities, 2)
        XCTAssertEqual(parser.pendingBytes, 0)
    }
    func testTolerantSequencePolicyStillRejectsMalformedPackets() throws {
        var badAudio = audio(first: 0); badAudio[9] = 0
        XCTAssertThrowsError(try FrameParser(requireContinuousAudio: false).feed(badAudio))
        var badControl = Data([0xaa, 0, 58] + control(sequence: 1, pressed: false) + [0xa5])
        badControl[25] ^= 1
        XCTAssertThrowsError(try FrameParser(requireContinuousAudio: false).feed(badControl))
        var badTrailer = audio(first: 0); badTrailer[badTrailer.count - 1] = 0
        XCTAssertThrowsError(try FrameParser(requireContinuousAudio: false).feed(badTrailer))
    }
    func testControlChecksumAndTrailer() throws {
        let c = control(sequence: 1, pressed: false)
        let bytes = Data([0xaa,0,58] + c + [0xa5])
        XCTAssertEqual(try FrameParser().feed(bytes).first?.control, c)
        var damaged = bytes; damaged[25] ^= 1
        XCTAssertThrowsError(try FrameParser().feed(damaged))
        var version = c; version[2] = 8; version[3] = crc8(Array(version.prefix(3)))
        let sum = crc16(Array(version.dropLast(2))); version[56] = UInt8(sum & 255); version[57] = UInt8(sum >> 8)
        XCTAssertThrowsError(try FrameParser().feed(Data([0xaa,0,58] + version + [0xa5])))
        var trailer = bytes; trailer[trailer.count-1] = 0
        XCTAssertThrowsError(try FrameParser().feed(trailer))
    }
    func testButtonBaselineDedupAndSessionTimeout() {
        let b = LinkButtonDetector()
        XCTAssertFalse(b.observe(control(sequence: 1, pressed: true), time: 0))
        XCTAssertFalse(b.observe(control(sequence: 2, pressed: false), time: 0.5))
        XCTAssertTrue(b.observe(control(sequence: 3, pressed: true), time: 1))
        XCTAssertFalse(b.observe(control(sequence: 3, pressed: true), time: 1.1))
        XCTAssertFalse(b.observe(control(sequence: 4, pressed: false), time: 1.5))
        XCTAssertFalse(b.observe(control(sequence: 5, pressed: true), time: 5))
    }
    func testWAVHeaderClippingAndNoOverwrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url)
        try writer.append([-2,0,2]); try writer.finish(); try writer.finish()
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(bytes.count, 50)
        XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(Array(bytes[24..<28]), [0x80,0xbb,0,0])
        XCTAssertEqual(Array(bytes[44..<50]), [0,128,0,0,255,127])
        XCTAssertThrowsError(try WAVWriter(url: url))
    }
    func testInvalidImportRemovesPartialOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("raw"), output = dir.appendingPathComponent("out.wav")
        try Data([0xaa,0x14]).write(to: input)
        XCTAssertThrowsError(try decodeCapture(input: input, output: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
