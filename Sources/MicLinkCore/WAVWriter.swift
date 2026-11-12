import Foundation

public final class WAVWriter {
    private let file: FileHandle
    public let url: URL
    public private(set) var samples = 0
    private var finished = false
    public init(url: URL) throws {
        self.url = url
        guard !FileManager.default.fileExists(atPath: url.path) else { throw StreamError.invalid("输出文件已存在") }
        guard FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 44),
                                            attributes: [.posixPermissions: 0o600]) else { throw StreamError.invalid("不能创建 WAV") }
        file = try FileHandle(forWritingTo: url)
        try file.seek(toOffset: 44)
    }
    public func append(_ pcm: [Float]) throws {
        guard !finished, pcm.allSatisfy({ $0.isFinite }), samples + pcm.count < 1_000_000_000 else {
            throw StreamError.invalid("无效 PCM 或文件已关闭")
        }
        var bytes = Data(); bytes.reserveCapacity(pcm.count*2)
        for value in pcm {
            let bounded = max(-1, min(1, value))
            let v = Int16(max(-32768, min(32767, Int((bounded * 32768).rounded()))))
            let u = UInt16(bitPattern: v)
            bytes.append(UInt8(u & 255)); bytes.append(UInt8(u >> 8))
        }
        try file.write(contentsOf: bytes); samples += pcm.count
    }
    public func finish() throws {
        guard !finished else { return }
        var h = Data()
        func text(_ s: String) { h.append(contentsOf: s.utf8) }
        func u16(_ v: UInt16) { h.append(UInt8(v & 255)); h.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for i in 0..<4 { h.append(UInt8((v >> (i*8)) & 255)) } }
        let count = UInt32(samples*2)
        text("RIFF"); u32(36+count); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(48000); u32(96000); u16(2); u16(16); text("data"); u32(count)
        try file.seek(toOffset: 0); try file.write(contentsOf: h); try file.synchronize(); try file.close()
        finished = true
    }
    deinit { try? finish() }
}

public struct DecodeSummary: Codable {
    public let frames: Int
    public let samples: Int
    public let seconds: Double
    public let controlFrames: Int
    public let peak: Float
}

/// File-only verification. No Bluetooth/audio device APIs are linked by this target.
public func decodeCapture(input: URL, output: URL) throws -> DecodeSummary {
    let reader = try FileHandle(forReadingFrom: input)
    defer { try? reader.close() }
    let parser = FrameParser(), decoder = try LC3Decoder(), writer = try WAVWriter(url: output)
    var count = 0, controls = 0; var peak: Float = 0
    do {
        while let chunk = try reader.read(upToCount: 65536), !chunk.isEmpty {
            for envelope in try parser.feed(chunk) {
                if envelope.control != nil { controls += 1 }
                for packet in envelope.audio {
                    let pcm = try decoder.decode(packet)
                    peak = max(peak, pcm.map(abs).max() ?? 0)
                    try writer.append(pcm); count += 1
                }
            }
        }
        guard parser.pendingBytes == 0, count > 0 else { throw StreamError.invalid("文件不完整或没有音频") }
        try writer.finish()
        return DecodeSummary(frames: count, samples: writer.samples, seconds: Double(writer.samples)/48000,
                             controlFrames: controls, peak: peak)
    } catch {
        try? writer.finish()
        try? FileManager.default.removeItem(at: output)
        throw error
    }
}
