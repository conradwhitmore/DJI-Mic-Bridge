// Research helper, not part of the menu-bar app. Run through watch_mic2_buttons.py.
// Receives only: no application-level writes and no audio/keyboard/configuration APIs.
import Foundation
import IOBluetooth
import Darwin

setbuf(stdout, nil)
let timestampFormatter = ISO8601DateFormatter()
timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func emit(_ fields: [String: Any]) {
    var value = fields
    value["time"] = timestampFormatter.string(from: Date())
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line) }
}

let arguments = CommandLine.arguments
guard arguments.count == 4, arguments[1] == "--listen",
      arguments[2].range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil,
      let duration = Double(arguments[3]), duration >= 10, duration <= 120 else {
    print("Preview only. Live use requires the watchdog wrapper, an address and a 10–120 second limit.")
    exit(0)
}

final class Receiver: NSObject, IOBluetoothRFCOMMChannelDelegate {
    let device: IOBluetoothDevice
    let duration: Double
    var channel: IOBluetoothRFCOMMChannel?
    var stopping = false
    var opened = false
    var pollTimer: Timer?
    var timeoutTimer: Timer?
    var openDeadline: Timer?
    var signals: [DispatchSourceSignal] = []

    init(device: IOBluetoothDevice, duration: Double) { self.device = device; self.duration = duration }

    func stop(_ reason: String) {
        guard !stopping else { return }
        stopping = true
        pollTimer?.invalidate()
        timeoutTimer?.invalidate()
        openDeadline?.invalidate()
        emit(["kind": "stopping", "reason": reason])
        var closeStatus: IOReturn = 0
        if let current = channel {
            _ = current.setDelegate(nil)
            closeStatus = current.close()
        }
        channel = nil
        emit(["kind": "closed", "reason": reason, "close_status": closeStatus])
        // Drain callbacks briefly, then destroy the process and its framework client.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }

    func start() {
        guard device.isConnected() else { emit(["kind": "refused", "reason": "device_not_connected"]); exit(2) }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop("cancelled") }
            source.resume()
            signals.append(source)
        }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.stop("time_limit")
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.stopping else { return }
            if !self.device.isConnected() { self.stop("device_disconnected") }
        }
        emit(["kind": "initializing"])
        // The earlier failure was caused by requesting a channel before the shim initialized.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, !self.stopping else { return }
            guard self.device.isConnected() else { self.stop("device_disconnected"); return }
            self.openDeadline = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                self?.stop("open_timeout")
            }
            let status = self.device.openRFCOMMChannelAsync(&self.channel, withChannelID: 10, delegate: self)
            emit(["kind": "open_requested", "status": status])
            if status != 0 { self.stop("open_request_failed") }
        }
    }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard !stopping else { _ = channel?.close(); return }
        guard error == 0, channel?.isOpen() == true else { stop("open_failed"); return }
        guard !opened else { stop("unexpected_reopen"); return }
        opened = true
        openDeadline?.invalidate()
        emit(["kind": "opened"])
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        guard !stopping, opened else { return }
        guard let pointer = pointer, count >= 0, count <= 65536 else { stop("invalid_receive_size"); return }
        // IPC to the wrapper: button watcher redacts; authorized stream capture saves locally.
        emit(["kind": "rx", "data": Data(bytes: pointer, count: count).base64EncodedString()])
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) { stop("channel_closed") }
}

guard let device = IOBluetoothDevice(addressString: arguments[2]) else { exit(2) }
let receiver = Receiver(device: device, duration: duration)
receiver.start()
RunLoop.main.run()
