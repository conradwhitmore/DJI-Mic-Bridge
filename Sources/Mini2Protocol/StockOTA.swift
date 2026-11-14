import Foundation
import CryptoKit

public enum Mini2OTAError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

/// Only the exact, unmodified official 02.03.17.00 package is accepted.
/// No re-compression, patching, downgrade, RX update or arbitrary-file mode.
public struct Mini2StockImage {
    public static let packageSHA256 = "c95003882b55779382b950fe5a1090f6af8eb641738feffad703f4aafacc122d"
    public static let txSHA256 = "77c9354d9e320363a18cb0069eb473a454a9b48765dfb8133da10aac9ed8f27f"
    public let bytes: Data
    public init(package: Data) throws {
        guard package.count == 1_463_978, Self.sha(package) == Self.packageSHA256 else {
            throw Mini2OTAError.invalid("仅接受完整官方 02.03.17.00 原包；SHA-256 不匹配")
        }
        let b = [UInt8](package)
        let start = Int(OTAFrame.uint(b, at: 72, size: 4)), size = Int(OTAFrame.uint(b, at: 76, size: 4))
        guard b[64] == 0x3a, start == 170, size == 724_992 else { throw Mini2OTAError.invalid("TX 模块目录不符") }
        bytes = package.subdata(in: start..<start + size)
        guard Self.sha(bytes) == Self.txSHA256, bytes.prefix(4) == Data("AOTA".utf8) else {
            throw Mini2OTAError.invalid("TX 镜像不符")
        }
    }
    public static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct OTAFrame: Equatable {
    public let command: UInt8
    public let payload: [UInt8]
    public init(_ command: UInt8, _ payload: [UInt8] = []) { self.command = command; self.payload = payload }
    public var data: Data { Data([9, command, 0x80] + Self.le(UInt32(payload.count), size: 2) + payload) }
    public static func le(_ value: UInt32, size: Int) -> [UInt8] { (0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    public static func uint(_ b: [UInt8], at: Int = 0, size: Int) -> UInt32 {
        (0..<size).reduce(0) { $0 | UInt32(b[at + $1]) << ($1 * 8) }
    }
    public static func tlv(_ type: UInt8, _ value: UInt32, size: Int) -> [UInt8] {
        [type] + le(UInt32(size), size: 2) + le(value, size: size)
    }
    public func fields() throws -> [UInt8: [UInt8]] {
        var offset = 0, result: [UInt8: [UInt8]] = [:]
        while offset < payload.count {
            guard payload.count - offset >= 3 else { throw Mini2OTAError.invalid("OTA TLV 头截断") }
            let type = payload[offset], n = Int(Self.uint(payload, at: offset + 1, size: 2))
            offset += 3
            guard n <= payload.count - offset, result[type] == nil else { throw Mini2OTAError.invalid("OTA TLV 长度或重复字段异常") }
            result[type] = Array(payload[offset..<offset + n]); offset += n
        }
        return result
    }
    public static func value(_ fields: [UInt8: [UInt8]], _ type: UInt8, size: Int) throws -> UInt32 {
        guard let b = fields[type], b.count == size else { throw Mini2OTAError.invalid("OTA 缺少字段 \(type) 或长度不符") }
        return uint(b, size: size)
    }
    public static func crc32(_ b: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for v in b {
            crc ^= UInt32(v)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        return crc ^ 0xffff_ffff
    }
}

/// OTA is an ordered byte stream. Never resynchronize a corrupt upgrade stream silently.
public struct OTAParser {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func feed(_ data: Data) throws -> [OTAFrame] {
        buffer += data
        guard buffer.count <= 65_536 else { throw Mini2OTAError.invalid("OTA 接收缓冲溢出") }
        var frames: [OTAFrame] = []
        while buffer.count >= 5 {
            guard buffer[0] == 9, buffer[2] == 0x80 else { throw Mini2OTAError.invalid("OTA 帧头异常") }
            let n = Int(OTAFrame.uint(buffer, at: 3, size: 2))
            guard n <= 4096 else { throw Mini2OTAError.invalid("OTA 控制帧过长") }
            guard buffer.count >= n + 5 else { break }
            frames.append(OTAFrame(buffer[1], Array(buffer[5..<5+n]))); buffer.removeFirst(5+n)
        }
        return frames
    }
}

/// Actual target handlers: 1004A224 / A364 / A090 / A488 / A588.
/// Host only answers device-requested ranges. ATT acknowledgments are not flash success.
public struct Mini2OTAHost {
    public enum Phase: Equatable { case idle, request, negotiation, transfer, validated, rejected }
    public private(set) var phase = Phase.idle
    public private(set) var unitSize = 0
    public private(set) var requestedRanges: [Range<Int>] = []
    private let image: [UInt8]
    private let maximumPacket: Int
    public init(image: Data, maximumPacket: Int) { self.image = Array(image); self.maximumPacket = maximumPacket }
    public mutating func start() throws -> OTAFrame {
        guard phase == .idle, maximumPacket >= 20, !image.isEmpty else { throw Mini2OTAError.invalid("OTA 启动条件不符") }
        phase = .request
        return OTAFrame(1, OTAFrame.tlv(9, 1, size: 1) + OTAFrame.tlv(10, 0, size: 4))
    }
    public mutating func receive(_ frame: OTAFrame) throws -> [OTAFrame] {
        let f = try frame.fields()
        switch (phase, frame.command) {
        case (.request, 1):
            let code = try OTAFrame.value(f, 0x7f, size: 4)
            guard code == 100_000 else { phase = .rejected; throw Mini2OTAError.invalid("设备拒绝 OTA：\(code)") }
            guard try OTAFrame.value(f, 9, size: 1) & 1 == 1 else { throw Mini2OTAError.invalid("设备未确认分块 CRC 支持") }
            phase = .negotiation; return [OTAFrame(2)]
        case (.negotiation, 2):
            let advertised = Int(try OTAFrame.value(f, 3, size: 2))
            guard advertised >= 20, advertised <= 4096,
                  try OTAFrame.value(f, 5, size: 1) == 0,
                  try OTAFrame.value(f, 4, size: 2) == 0 else { throw Mini2OTAError.invalid("未知 OTA 分块/流控参数") }
            // Stay below both the target's advertised unit and one ATT write.
            unitSize = min(advertised - 10, maximumPacket - 10, 128)
            phase = .transfer; return [OTAFrame(9, OTAFrame.tlv(1, 1, size: 1))]
        case (.transfer, 3):
            let offset = Int(try OTAFrame.value(f, 1, size: 4)), length = Int(try OTAFrame.value(f, 2, size: 4))
            guard try OTAFrame.value(f, 3, size: 1) == 0,
                  offset <= image.count, length > 0, length <= image.count - offset else {
                throw Mini2OTAError.invalid("设备请求越界或未知读取方式：\(offset)+\(length)")
            }
            requestedRanges.append(offset..<offset + length)
            var packets: [OTAFrame] = [], p = offset, sequence: UInt8 = 0
            while p < offset + length {
                let n = min(unitSize, offset + length - p), b = Array(image[p..<p+n])
                packets.append(OTAFrame(0x0b, [sequence] + OTAFrame.le(OTAFrame.crc32(b), size: 4) + b))
                p += n; sequence &+= 1
            }
            return packets
        case (.transfer, 6):
            let valid = try OTAFrame.value(f, 1, size: 1)
            guard valid <= 1 else { throw Mini2OTAError.invalid("未知 OTA 校验结果") }
            phase = valid == 1 ? .validated : .rejected
            // Mimo 2.12.9 SendValidateImageDataAck (0x102C386C4).
            return [OTAFrame(6)]
        default: throw Mini2OTAError.invalid("OTA 阶段 \(phase) 收到未预期命令 \(frame.command)")
        }
    }
}
