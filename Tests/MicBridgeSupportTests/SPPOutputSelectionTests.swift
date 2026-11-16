import XCTest
@testable import MicBridgeSupport

final class SPPOutputSelectionTests: XCTestCase {
    private let speaker = SPPOutputSelection.Candidate(id: 1, uid: "speaker", builtIn: true)
    private let usb = SPPOutputSelection.Candidate(id: 2, uid: "usb")
    private let headphones = SPPOutputSelection.Candidate(id: 3, uid: "bluetooth-headphones")
    func testUserCanSwitchBetweenAllowedOutputs() {
        let devices = [speaker, usb, headphones]
        XCTAssertEqual(SPPOutputSelection.choose(devices, current: 2, previousUID: "speaker"), 2)
        XCTAssertEqual(SPPOutputSelection.choose(devices, current: 3, previousUID: "usb"), 3)
    }
    func testDJISelectionReturnsToLastOutputByStableIdentity() {
        let replugged = SPPOutputSelection.Candidate(id: 22, uid: "usb")
        XCTAssertEqual(SPPOutputSelection.choose([speaker, replugged], current: 99, previousUID: "usb"), 22)
        XCTAssertEqual(SPPOutputSelection.choose([speaker, headphones], current: 99, previousUID: "usb"), 1)
    }
    func testMissingOutputDoesNotAutomaticallySelectLoopback() {
        let bridge = SPPOutputSelection.Candidate(id: 4, uid: "bridge", fallback: false)
        XCTAssertNil(SPPOutputSelection.choose([bridge], current: 99, previousUID: nil))
        XCTAssertEqual(SPPOutputSelection.choose([bridge, speaker], current: 99, previousUID: nil), 1)
        XCTAssertEqual(SPPOutputSelection.choose([bridge, speaker], current: 4, previousUID: nil), 4)
    }
}
