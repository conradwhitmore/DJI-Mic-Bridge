import XCTest
import Mini2Protocol

final class FirmwareImageTests: XCTestCase {
    func testRejectsTruncatedWrongSizeAndUnapprovedPackagesInBothModes() {
        for kind in Mini2FirmwareImage.Kind.allCases {
            for count in [0, 169, 725_162, 1_463_978] {
                XCTAssertThrowsError(try Mini2FirmwareImage(package: Data(repeating: 0, count: count), kind: kind))
            }
        }
    }
    func testLocalApprovedPackagesAreMutuallyExclusiveAndCorruptionIsRejected() throws {
        guard let stockPath = ProcessInfo.processInfo.environment["MINI2_STOCK_PACKAGE"],
              let patchPath = ProcessInfo.processInfo.environment["MINI2_R2_PACKAGE"] else {
            throw XCTSkip("Official and experimental firmware are not distributed in source; set local fixture paths")
        }
        let stock = try Data(contentsOf: URL(fileURLWithPath: stockPath))
        let patch = try Data(contentsOf: URL(fileURLWithPath: patchPath))
        XCTAssertEqual(try Mini2FirmwareImage(package: stock, kind: .official).bytes.count, 724_992)
        XCTAssertEqual(try Mini2FirmwareImage(package: patch, kind: .advanced).bytes.count, 724_992)
        XCTAssertThrowsError(try Mini2FirmwareImage(package: stock, kind: .advanced))
        XCTAssertThrowsError(try Mini2FirmwareImage(package: patch, kind: .official))
        for (file, kind) in [(stock, Mini2FirmwareImage.Kind.official), (patch, .advanced)] {
            for offset in [0, 64, 72, 170, file.count / 2, file.count - 1] {
                var corrupt = file; corrupt[offset] ^= 1
                XCTAssertThrowsError(try Mini2FirmwareImage(package: corrupt, kind: kind))
            }
        }
    }
}
