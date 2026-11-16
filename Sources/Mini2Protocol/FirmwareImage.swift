import Foundation

/// Whitelisted full packages only. Original and patched firmware are never interchangeable.
public struct Mini2FirmwareImage {
    public enum Kind: String, CaseIterable { case advanced, official }
    public static let advancedSHA256 = "a8ccde775a0fcebf41a9760ead12ade4989c8bf419502aaa2fd9a2269ec6f17f"
    public static let advancedTXSHA256 = "4f7d71f5dfd4a33828956ff9ed739e5b3ef074b3cd7e8596a393db2f287f5b4e"
    public let bytes: Data
    public let kind: Kind
    public init(package: Data, kind: Kind) throws {
        self.kind = kind
        if kind == .official { bytes = try Mini2StockImage(package: package).bytes; return }
        guard package.count == 1_463_978, Mini2StockImage.sha(package) == Self.advancedSHA256 else {
            throw Mini2OTAError.invalid("请选择完整的 Mini 2 MBRG r2 补丁包；SHA-256 不匹配")
        }
        let b = [UInt8](package)
        guard b[64] == 0x3a, OTAFrame.uint(b, at: 72, size: 4) == 170,
              OTAFrame.uint(b, at: 76, size: 4) == 724_992 else { throw Mini2OTAError.invalid("Mini 2 TX 模块目录不符") }
        bytes = package.subdata(in: 170..<725_162)
        guard Mini2StockImage.sha(bytes) == Self.advancedTXSHA256, bytes.prefix(4) == Data("AOTA".utf8) else {
            throw Mini2OTAError.invalid("Mini 2 TX 镜像校验失败")
        }
    }
}
