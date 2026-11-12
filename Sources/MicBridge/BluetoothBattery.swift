import Foundation
import IOBluetooth
import ObjectiveC

/// Reads the OS cache only; never creates an audio stream or Bluetooth connection.
/// batteryPercentSingle is not public SDK API. Check availability and ABI before use.
/// Reference: fky1990/DJI-Mic-2-Bridge, AppDelegate.m (MIT).
enum BluetoothBattery {
    static func percent(for device: IOBluetoothDevice) -> Int? {
        guard device.isConnected(), let address = device.addressString,
              let current = IOBluetoothDevice(addressString: address), current.isConnected() else { return nil }
        let selector = NSSelectorFromString("batteryPercentSingle")
        guard current.responds(to: selector),
              let method = class_getInstanceMethod(type(of: current), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "C" else { return nil }
        typealias ReadPercent = @convention(c) (AnyObject, Selector) -> UInt8
        let read = unsafeBitCast(method_getImplementation(method), to: ReadPercent.self)
        let raw = Int(read(current, selector))
        // Zero is also used for an unpopulated system cache; don't claim an empty battery.
        return (1...100).contains(raw) ? raw : nil
    }
}
