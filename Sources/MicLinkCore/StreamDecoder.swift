import Foundation
import CLc3

public enum StreamError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

public func crc8(_ bytes: [UInt8]) -> UInt8 {
    var v: UInt8 = 0x77
    for b in bytes { v ^= b; for _ in 0..<8 { v = (v >> 1) ^ (v & 1 == 1 ? 0x8c : 0) } }
    return v
}
public func crc16(_ bytes: [UInt8]) -> UInt16 {
    var v: UInt16 = 0x3692
    for b in bytes { v ^= UInt16(b); for _ in 0..<8 { v = (v >> 1) ^ (v & 1 == 1 ? 0x8408 : 0) } }
    return v
}

public struct Envelope {
    public let audio: [Data]
    public let control: [UInt8]?
}

/// Validates framing and controls. Sequence-gap rejection remains the default for the Demo.
public final class FrameParser {
    private var buffer: [UInt8] = []
    private var lastSequence: UInt8?
    private let requireContinuousAudio: Bool
    public private(set) var audioDiscontinuities = 0
    public var pendingBytes: Int { buffer.count }
    public init(requireContinuousAudio: Bool = true) {
        self.requireContinuousAudio = requireContinuousAudio
    }
    public func feed(_ data: Data) throws -> [Envelope] {
        guard buffer.count + data.count <= 1_048_576 else { throw StreamError.invalid("接收缓冲区超限") }
        buffer.append(contentsOf: data)
        var result: [Envelope] = []
        while buffer.count >= 3 {
            let tag = buffer[1], n = Int(buffer[2])
            guard buffer[0] == 0xaa, tag == 0 || tag == 0x14,
                  n >= 13 || (tag == 0x14 && n == 0) else { throw StreamError.invalid("未知 SPP 封装") }
            let offset = tag == 0x14 ? 628 : 3, total = offset + n + 1
            if buffer.count < total { break }
            guard buffer[total - 1] == 0xa5 else { throw StreamError.invalid("SPP 尾标记错误") }
            let control = n > 0 ? Array(buffer[offset..<offset+n]) : nil
            if let c = control {
                guard c[0] == 0x55, c[2] >> 2 == 1, (Int(c[1]) | Int(c[2]) << 8) & 0x3ff == n,
                      crc8(Array(c[0..<3])) == c[3],
                      crc16(Array(c.dropLast(2))) == UInt16(c[n-2]) | UInt16(c[n-1]) << 8
                else { throw StreamError.invalid("DUML 长度或校验错误") }
            }
            var audio: [Data] = []
            if tag == 0x14 {
                for i in 0..<5 {
                    let p = Array(buffer[(3+i*125)..<(3+(i+1)*125)])
                    guard p[6...8].elementsEqual([0x55,0x77,0x05]), p[124] == 0 else {
                        throw StreamError.invalid("未知音频块格式")
                    }
                    if let previous = lastSequence, p[12] != previous &+ 1 {
                        audioDiscontinuities += 1
                        if requireContinuousAudio {
                            throw StreamError.invalid("音频序号不连续；停止以免拼接错误")
                        }
                    }
                    lastSequence = p[12]
                    audio.append(Data(p[13..<124]))
                }
            }
            result.append(Envelope(audio: audio, control: control))
            buffer.removeFirst(total)
        }
        return result
    }
}

public final class LinkButtonDetector {
    private var lastSequence: UInt16?
    private var lastTime: TimeInterval?
    private var pressed: Bool?
    public init() {}
    public func observe(_ c: [UInt8], time: TimeInterval) -> Bool {
        guard c.count == 58, c[2] >> 2 == 1, c[4] == 0x3a, c[5] == 2,
              c[8] == 0, c[9] == 2, c[10] == 0xff else { return false }
        if let previousTime = lastTime, time < previousTime || time - previousTime > 3 {
            lastSequence = nil; pressed = nil
        }
        let sequence = UInt16(c[6]) | UInt16(c[7]) << 8
        if let previous = lastSequence {
            let delta = sequence &- previous
            if delta == 0 || delta >= 0x8000 { return false }
        }
        let next = c[20] & 8 != 0
        let rising = pressed == false && next
        lastSequence = sequence; lastTime = time; pressed = next
        return rising
    }
}

public final class LC3Decoder {
    private let memory: UnsafeMutableRawPointer
    private let handle: lc3_decoder_t
    public init() throws {
        let count = Int(lc3_hr_decoder_size(false, 5000, 48000))
        guard count > 0 else { throw StreamError.invalid("LC3 配置不受支持") }
        memory = .allocate(byteCount: count, alignment: 16)
        guard let h = lc3_hr_setup_decoder(false, 5000, 48000, 0, memory) else {
            memory.deallocate(); throw StreamError.invalid("LC3 初始化失败")
        }
        handle = h
    }
    deinit { memory.deallocate() }
    public func decode(_ data: Data) throws -> [Float] {
        guard data.count == 111 else { throw StreamError.invalid("LC3 音频帧不是 111 字节") }
        var output = [Float](repeating: 0, count: 240)
        let status = data.withUnsafeBytes { bytes in
            output.withUnsafeMutableBytes { pcm in
                lc3_decode(handle, bytes.baseAddress, 111, LC3_PCM_FORMAT_FLOAT, pcm.baseAddress, 1)
            }
        }
        guard status == 0, output.allSatisfy({ $0.isFinite }) else {
            throw StreamError.invalid("LC3 解码失败或需要丢包补偿；已停止")
        }
        return output
    }
}
