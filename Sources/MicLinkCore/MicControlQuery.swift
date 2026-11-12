import Foundation

/// Fixed research commands. Reconnect deletion accepts only an explicit peer MAC.
public enum MicControlCommand: String, CaseIterable {
    case version, audioConfiguration, deviceAddress, deleteSPPReconnect, battery
    case vibrationOff, vibrationOn
    case keyTestOn, keyTestOff
    case denoiseOn, denoiseOff
    // Preserve the original Demo's command list. MicBridge opts into battery explicitly.
    public static let allCases: [MicControlCommand] = [.version, .audioConfiguration, .deviceAddress, .deleteSPPReconnect]
    public var title: String {
        switch self {
        case .version: return "查询 TX 版本"
        case .audioConfiguration: return "读取 TX 配置"
        case .deviceAddress: return "读取 TX 地址"
        case .deleteSPPReconnect: return "清除本 Mac 的 SPP 重连记录（实验）"
        case .battery: return "读取 TX 电量"
        case .vibrationOff: return "关闭振动通知"
        case .vibrationOn: return "开启振动通知"
        case .denoiseOn: return "开启降噪"
        case .denoiseOff: return "关闭降噪"
        case .keyTestOn: return "进入独立按键测试"
        case .keyTestOff: return "退出独立按键测试"
        }
    }
    public var code: (UInt8, UInt8) {
        switch self {
        case .version: return (0, 1)
        case .audioConfiguration: return (2, 0xa0)
        case .deviceAddress: return (0x12, 0x0c)
        case .deleteSPPReconnect: return (0x12, 0x65)
        case .battery: return (0x05, 0x06)
        case .vibrationOff, .vibrationOn, .denoiseOn, .denoiseOff: return (2, 0x9f)
        case .keyTestOn, .keyTestOff: return (4, 0x68)
        }
    }
    public var replyPayloadLength: Int {
        switch self {
        case .version: return 30
        case .audioConfiguration: return 28
        case .deviceAddress: return 7
        case .deleteSPPReconnect: return 1
        case .battery: return 40
        case .vibrationOff, .vibrationOn, .denoiseOn, .denoiseOff: return 1
        case .keyTestOn, .keyTestOff: return 4
        }
    }
}

public struct MicControlQuery {
    public let command: MicControlCommand
    public let sequence: UInt16
    private let requestPayload: [UInt8]
    public init(command: MicControlCommand, sequence: UInt16, peerAddress: String? = nil,
                audioConfiguration: Mic2AudioConfiguration? = nil) throws {
        self.command = command; self.sequence = sequence
        if command == .keyTestOn || command == .keyTestOff {
            // TX 04.05.01.11: 0x102beb8 -> 0x102bf80; no 02/9F write.
            requestPayload = [0x43, 1, command == .keyTestOn ? 1 : 0]
        } else if command == .vibrationOff || command == .vibrationOn {
            guard let audioConfiguration else { throw StreamError.invalid("请先读取当前 TX 配置") }
            requestPayload = try audioConfiguration.vibrationWritePayload(enabled: command == .vibrationOn)
        } else if command == .denoiseOn || command == .denoiseOff {
            guard let audioConfiguration else { throw StreamError.invalid("请先读取当前 TX 配置") }
            requestPayload = try audioConfiguration.denoiseWritePayload(enabled: command == .denoiseOn)
        } else if command == .deleteSPPReconnect {
            guard let peerAddress,
                  peerAddress.range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil else {
                throw StreamError.invalid("删除重连记录需要有效的本机蓝牙地址")
            }
            let bytes = peerAddress.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard bytes.count == 6, bytes.contains(where: { $0 != 0 }), bytes[0] & 1 == 0 else {
                throw StreamError.invalid("本机蓝牙地址不可用")
            }
            // TX firmware converts display-order BT_MAC to internal bd_addr by
            // swapping 0↔5, 1↔4, 2↔3 (04.05.01.11: 0x01080e92..0x01080ec8).
            requestPayload = [1] + bytes.reversed()
        } else { requestPayload = [] }
    }
    public var packet: [UInt8] {
        let (set, id) = command.code
        var c: [UInt8] = [0x55, UInt8(13 + requestPayload.count), 4, 0, 2, 0x3a, UInt8(sequence & 255), UInt8(sequence >> 8), 0x40, set, id]
        c[3] = crc8(Array(c.prefix(3)))
        c += requestPayload
        let sum = crc16(c); c += [UInt8(sum & 255), UInt8(sum >> 8)]
        return [0xaa, 0, UInt8(c.count)] + c + [0xa5]
    }
    /// Nil means an unrelated push/reply. A matching malformed/error reply throws.
    public func reply(_ c: [UInt8]) throws -> [UInt8]? {
        guard c.count >= 13 else { return nil }
        let (set, id) = command.code
        guard c[4] == 0x3a, c[5] == 2, c[8] == 0x80, c[9] == set, c[10] == id,
              UInt16(c[6]) | UInt16(c[7]) << 8 == sequence else { return nil }
        guard c[0] == 0x55, c[2] >> 2 == 1,
              (Int(c[1]) | Int(c[2]) << 8) & 0x3ff == c.count,
              crc8(Array(c.prefix(3))) == c[3],
              crc16(Array(c.dropLast(2))) == UInt16(c[c.count-2]) | UInt16(c[c.count-1]) << 8
        else { throw StreamError.invalid("指令应答 CRC 或长度错误") }
        let payload = Array(c[11..<c.count-2])
        if command == .battery {
            // TX 04.04.05.13 / 04.05.01.11: the first byte IS the percentage,
            // not a status code. The 40-byte reply is copied by the ACK helper.
            guard payload.count == command.replyPayloadLength else { throw StreamError.invalid("电量应答格式不同：\(payload.count) 字节") }
            guard payload[0] <= 100 else { throw StreamError.invalid("设备电量数值超出范围") }
            return payload
        }
        guard let status = payload.first else { throw StreamError.invalid("指令应答没有返回码") }
        guard status == 0 else { throw StreamError.invalid(String(format: "设备返回错误码 %02X", status)) }
        guard payload.count == command.replyPayloadLength else { throw StreamError.invalid("当前固件应答格式不同：\(payload.count) 字节") }
        if command == .keyTestOn || command == .keyTestOff {
            guard payload == [0, 0x43, 1, command == .keyTestOn ? 1 : 0] else {
                throw StreamError.invalid("按键测试应答未确认请求的模式")
            }
        }
        return payload
    }
    public func summary(_ payload: [UInt8]) -> String {
        guard payload.count == command.replyPayloadLength else { return "应答长度不符" }
        switch command {
        case .version: return "TX 固件 " + payload[22..<26].reversed().map { String(format: "%02d", Int($0)) }.joined(separator: ".")
        case .audioConfiguration: return "TX 配置：" + payload.dropFirst().map { String(format: "%02X", $0) }.joined(separator: " ")
        case .deviceAddress: return "TX 地址原始字节：" + payload.dropFirst().map { String(format: "%02X", $0) }.joined(separator: ":")
        case .deleteSPPReconnect: return "12/65 已回复 ACK 00；重连记录是否生效仍需退出测试"
        case .battery: return "TX 电量 \(payload[0])%"
        case .vibrationOff, .vibrationOn: return "振动设置 ACK 00，等待回读"
        case .denoiseOn, .denoiseOff: return "降噪设置 ACK 00，等待回读"
        case .keyTestOn: return "按键测试已确认开启 · 等待 04/68 独立事件"
        case .keyTestOff: return "按键测试已确认退出"
        }
    }
}
