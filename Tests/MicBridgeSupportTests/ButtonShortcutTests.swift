import XCTest
@testable import MicBridgeSupport

final class ButtonShortcutTests: XCTestCase {
    func testDuplicateOutOfOrderAndDebounce() {
        var gate = ButtonShortcutGate()
        XCTAssertTrue(gate.accept(button: "link", sequence: 50, time: 1))
        XCTAssertFalse(gate.accept(button: "link", sequence: 50, time: 2))
        XCTAssertFalse(gate.accept(button: "link", sequence: 49, time: 2))
        XCTAssertFalse(gate.accept(button: "link", sequence: 51, time: 1.1))
        XCTAssertFalse(gate.accept(button: "link", sequence: 52, time: 0.9))
        XCTAssertTrue(gate.accept(button: "link", sequence: 53, time: 1.3))
    }
    func testSequenceWrapAndIndependentButtonsAndSessions() {
        var gate = ButtonShortcutGate()
        XCTAssertTrue(gate.accept(button: "link", sequence: 65535, time: 10))
        XCTAssertTrue(gate.accept(button: "record", sequence: 65535, time: 10))
        XCTAssertTrue(gate.accept(button: "link", sequence: 0, time: 11))
        gate = ButtonShortcutGate()
        XCTAssertTrue(gate.accept(button: "link", sequence: 0, time: 1))
        XCTAssertFalse(gate.accept(button: "link", sequence: 1, time: .nan))
    }
    func testConfigurationRoundTripAndUnsafeKeysRejected() throws {
        var settings = ButtonShortcutSettings()
        XCTAssertTrue(settings.bindings.isEmpty)
        settings.bindings = ["link": .functionKey, "record": .returnKey,
                             "power": ButtonShortcut(keyCode: 40, modifiers: (1 << 20) | (1 << 17), keyLabel: "K")]
        let restored = try JSONDecoder().decode(ButtonShortcutSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        // Older versions stored a master switch. Keep bindings even if it was off.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy["enabled"] = false
        let migrated = try JSONDecoder().decode(ButtonShortcutSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated.bindings, settings.bindings)
        XCTAssertEqual(restored.bindings["power"]?.title, "⇧⌘K")
        XCTAssertTrue(restored.bindings.values.allSatisfy(\.isValid))
        for key: UInt16 in [54, 55, 56, 57, 58, 59, 60, 61, 62, 128, 65535] {
            XCTAssertFalse(ButtonShortcut(keyCode: key, keyLabel: "bad").isValid)
        }
        XCTAssertFalse(ButtonShortcut(keyCode: 63, modifiers: 1 << 20, keyLabel: "fn").isValid)
        XCTAssertFalse(ButtonShortcut(keyCode: 0, modifiers: 1 << 30, keyLabel: "A").isValid)
    }
}
