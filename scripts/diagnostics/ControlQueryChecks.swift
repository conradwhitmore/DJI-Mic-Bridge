import Foundation
import MicLinkCore
func check(_ condition: Bool) { precondition(condition) }
func reply(_ command: MicControlCommand, _ seq: UInt16, status: UInt8 = 0) -> [UInt8] {
    let (set,id) = command.code
    var p = [UInt8](repeating:0,count:command.replyPayloadLength); p[0] = status
    if command == .version { p[22...25] = [31,2,5,4] }
    let n = p.count+13
    var c: [UInt8] = [0x55,UInt8(n),4,0,0x3a,2,UInt8(seq&255),UInt8(seq>>8),0x80,set,id]
    c[3] = crc8(Array(c.prefix(3))); c += p
    let sum=crc16(c); return c+[UInt8(sum&255),UInt8(sum>>8)]
}
func rejected(_ f: () throws -> Void) { do { try f(); fatalError("invalid reply accepted") } catch {} }
func audio(_ seq: UInt8) -> [UInt8] {
    var b: [UInt8] = [0xaa,0x14,0]
    for i in 0..<5 { var p = [UInt8](repeating:0,count:125); p[6...8] = [0x55,0x77,5]; p[12]=seq &+ UInt8(i); b += p }
    return b+[0xa5]
}
// Synthetic locally administered unicast address; never use a real device identifier.
for command in MicControlCommand.allCases {
    let q = try MicControlQuery(command:command,sequence:123,peerAddress:"02:11:22:33:44:55")
    let p=FrameParser(); let request=try p.feed(Data(q.packet)).first!.control!
    check(request.count == (command == .deleteSPPReconnect ? 20 : 13) && request[4]==2 && request[5]==0x3a && request[8]==0x40)
    if command == .deleteSPPReconnect {
        check(Array(request[11..<18]) == [1,0x55,0x44,0x33,0x22,0x11,0x02])
    }
    let ok=reply(command,123)
    check(try q.reply(ok) != nil)
    check(try q.reply(reply(command,124)) == nil)
    var wrong=ok; wrong[4]=2; check(try q.reply(wrong)==nil)
    rejected { var bad=ok; bad[bad.count-1] ^= 1; _=try q.reply(bad) }
    rejected { _=try q.reply(reply(command,123,status:1)) }
    if command == .version { check(q.summary(try q.reply(ok)!) == "TX 固件 04.05.02.31") }
}
let q=try MicControlQuery(command:.audioConfiguration,sequence:123)
let c=reply(.audioConfiguration,123)
let parser=FrameParser()
let frames=try parser.feed(Data(audio(0)+audio(5)+[0xaa,0,UInt8(c.count)]+c+[0xa5]))
check(frames.count==3)
check(try q.reply(frames.last!.control!) != nil)
rejected { _=try FrameParser().feed(Data(audio(0)+audio(6))) }
for bad in ["", "00:00:00:00:00:00", "02:11:22:33:44", "FF:FF:FF:FF:FF:FF", "02:11:22:33:44:GG"] {
    rejected { _ = try MicControlQuery(command:.deleteSPPReconnect,sequence:1,peerAddress:bad) }
}
rejected { _ = try MicControlQuery(command:.deleteSPPReconnect,sequence:1) }
print("PASS: 3 fixed read commands plus addressed reconnect deletion, CRC/address/sequence/status correlation, interleaved audio/control frames, unchanged strict parser")
