import XCTest
@testable import MicBridgeSupport

final class SPPInputSelectionTests: XCTestCase {
    private let usb = SPPInputSelection.Candidate(id: 1)
    private let builtIn = SPPInputSelection.Candidate(id: 2, builtIn: true)
    private let bridge = SPPInputSelection.Candidate(id: 3, bridge: .micBridge)
    private let blackHole = SPPInputSelection.Candidate(id: 4, bridge: .blackHole)

    func testMicBridgeWinsRegardlessOfEnumerationOrCurrentPhysicalInput() {
        for candidates in [[usb, blackHole, builtIn, bridge], [bridge, builtIn, usb, blackHole]] {
            for current: UInt32 in [1, 2, 4, 99] {
                XCTAssertEqual(SPPInputSelection.choose(candidates, current: current, locked: 1), 3)
            }
        }
    }
    func testSystemSwitchToDJICannotReplaceBridgeLock() {
        XCTAssertEqual(SPPInputSelection.choose([usb, bridge], current: 99, locked: 3), 3)
        XCTAssertEqual(SPPInputSelection.choose([usb, bridge], current: 1, locked: 3), 3)
    }
    func testDriverRemovalFallsBackAndReturnRestoresPriority() {
        XCTAssertEqual(SPPInputSelection.choose([usb, builtIn], current: 99, locked: 3), 2)
        XCTAssertEqual(SPPInputSelection.choose([usb, builtIn], current: 1, locked: 3), 1)
        XCTAssertEqual(SPPInputSelection.choose([usb, builtIn, bridge], current: 1, locked: 1), 3)
        XCTAssertEqual(SPPInputSelection.choose([usb, blackHole], current: 1, locked: 3), 4)
        XCTAssertNil(SPPInputSelection.choose([], current: 99, locked: 3))
    }
    func testPhysicalFallbackRemainsLockedWithoutBridge() {
        XCTAssertEqual(SPPInputSelection.choose([usb, builtIn], current: 2, locked: 1), 1)
        XCTAssertEqual(SPPInputSelection.choose([usb, builtIn], current: 1), 1)
    }
    func testOrdinaryAudioPermissionRequiresCompletedExitAndIsPerDevice() {
        let suite = "MicBridgeTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BridgePreferences(defaults: defaults)
        let address = "AA:BB:CC:DD:EE:FF"
        XCTAssertFalse(preferences.ordinaryAudioRestored(for: address))
        preferences.setOrdinaryAudioRestored(true, for: address)
        let restarted = BridgePreferences(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(restarted.ordinaryAudioRestored(for: "aa-bb-cc-dd-ee-ff"))
        XCTAssertFalse(restarted.ordinaryAudioRestored(for: "11:22:33:44:55:66"))
        // New SPP intent revokes the restore record; temporary quit/relaunch
        // and device power cycles do not grant it again.
        restarted.setOrdinaryAudioRestored(false, for: address)
        XCTAssertFalse(BridgePreferences(defaults: UserDefaults(suiteName: suite)!).ordinaryAudioRestored(for: address))
        restarted.setOrdinaryAudioRestored(true, for: "")
        XCTAssertFalse(restarted.ordinaryAudioRestored(for: ""))
    }
}
