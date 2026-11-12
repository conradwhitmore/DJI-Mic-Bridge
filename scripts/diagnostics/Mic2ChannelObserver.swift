// Metadata-only research observer. It is not part of the Demo or a recovery tool.
// No IOBluetooth API is called before the explicit, fully validated --observe branch.
import Foundation
import IOBluetooth
import Darwin

private let usage = """
Usage:
  mic2-channel-observer [--help]
  mic2-channel-observer [--preview] --device-address AA:BB:CC:DD:EE:FF --seconds 30 --output NEW_FILE.jsonl
  mic2-channel-observer --observe --device-address AA:BB:CC:DD:EE:FF --seconds 30 --output NEW_FILE.jsonl

Default and --preview: validate/describe only; no Bluetooth API calls or file writes.
--observe: register public RFCOMM open notifications, match the exact device, and
record channel metadata plus independent close notifications. SECONDS is an integer
from 10 through 180. OUTPUT must not exist; it is created as a regular 0600 file.
Both channel directions are observed. Service identity is always unknown: neither
an incoming channel nor channel 10 establishes SPP or HFP identity.
No connection, channel delegate, channel close, payload, SDP, audio or settings APIs.
Stop unregisters notifications at the deadline or on SIGTERM/SIGINT; a separate
watchdog exits after at most one additional second if normal cleanup is blocked.
An empty observation is not proof that no system-owned RFCOMM channel exists.
"""

private struct Options {
    var observe = false
    var preview = false
    var address: String?
    var seconds: Int?
    var output: String?
}

private struct ObserverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func normalizedAddress(_ value: String?) -> String? {
    guard let value = value else { return nil }
    let candidate = value.replacingOccurrences(of: "-", with: ":").uppercased()
    guard candidate.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil else {
        return nil
    }
    return candidate
}

private func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var seen = Set<String>()
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        guard seen.insert(flag).inserted else { throw ObserverError("Duplicate option: \(flag)") }
        switch flag {
        case "--observe": options.observe = true
        case "--preview": options.preview = true
        case "--device-address", "--seconds", "--output":
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw ObserverError("Missing value for \(flag)")
            }
            let value = arguments[index]
            if flag == "--device-address" {
                guard let address = normalizedAddress(value) else { throw ObserverError("Invalid device address") }
                options.address = address
            } else if flag == "--seconds" {
                guard value.range(of: "^[0-9]+$", options: .regularExpression) != nil,
                      let seconds = Int(value), (10...180).contains(seconds) else {
                    throw ObserverError("--seconds must be an integer from 10 through 180")
                }
                options.seconds = seconds
            } else {
                guard !value.isEmpty, !value.utf8.contains(0) else { throw ObserverError("Invalid output path") }
                options.output = value
            }
        default: throw ObserverError("Unknown option: \(flag)")
        }
        index += 1
    }
    guard !(options.observe && options.preview) else { throw ObserverError("Choose --preview or --observe") }
    if options.observe {
        guard options.address != nil, options.seconds != nil, options.output != nil else {
            throw ObserverError("--observe requires --device-address, --seconds and --output")
        }
    }
    return options
}

private final class PrivateJSONLines {
    private var descriptor: Int32
    private var bytesWritten = 0
    private let byteLimit = 1_048_576
    private let startedAt = DispatchTime.now().uptimeNanoseconds

    init(path: String) throws {
        descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw ObserverError("Cannot create new output file (errno \(errno)); no Bluetooth API was called")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw ObserverError("Cannot secure regular 0600 output file; no Bluetooth API was called")
        }
    }

    func append(_ fields: [String: Any]) throws {
        var event = fields
        let now = DispatchTime.now().uptimeNanoseconds
        event["schema_version"] = 1
        // Strings avoid loss of UInt64 precision in JSON consumers.
        event["monotonic_uptime_ns"] = String(now)
        event["elapsed_ns"] = String(now - startedAt)
        event["wall_time_unix_seconds"] = Date().timeIntervalSince1970
        var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        data.append(0x0a)
        guard bytesWritten + data.count <= byteLimit else { throw ObserverError("Metadata output limit reached") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ObserverError("Metadata output write failed (errno \(errno))") }
                offset += count
            }
        }
        bytesWritten += data.count
    }

    func finish() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    deinit { finish() }
}

private final class TrackedChannel {
    let observationID: Int
    var notification: IOBluetoothUserNotification?
    init(observationID: Int) { self.observationID = observationID }
}

private final class ChannelObserver: NSObject {
    private let address: String
    private let seconds: Int
    private let output: PrivateJSONLines
    private var openNotification: IOBluetoothUserNotification?
    private var channels: [UInt: TrackedChannel] = [:]
    private var nextObservationID = 0
    // Aggregate counts only: no identity or channel metadata for filtered devices.
    // "received" means handleOpened was entered on main, not all framework events
    // globally or callbacks still queued when this process exits.
    private var openCallbacksReceived = 0
    private var openCallbacksIgnoredAfterStop = 0
    private var openCallbacksTokenMismatch = 0
    private var openCallbacksAddressUnavailable = 0
    private var openCallbacksAddressNotTarget = 0
    private var openCallbacksTargetMatched = 0
    private var stopping = false
    private var deadline: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private let watchdogQueue = DispatchQueue(label: "mic2.metadata-observer.watchdog")

    init(address: String, seconds: Int, output: PrivateJSONLines) {
        self.address = address
        self.seconds = seconds
        self.output = output
    }

    // The fallback exits this observer only. It cannot guarantee a blocked framework
    // completed unregister(); process death releases this client's registrations.
    private static func forcedExit(_ code: Int32) -> Never {
        let message = "Observer hard limit: cleanup unconfirmed; no channel action was requested.\n"
        message.withCString { pointer in _ = Darwin.write(STDERR_FILENO, pointer, strlen(pointer)) }
        Darwin._exit(code)
    }

    func start() {
        let stopAt = DispatchTime.now() + .seconds(seconds)
        let hardLimit = DispatchSource.makeTimerSource(queue: watchdogQueue)
        hardLimit.schedule(deadline: stopAt + .seconds(1), leeway: .milliseconds(1))
        hardLimit.setEventHandler { Self.forcedExit(124) }
        hardLimit.resume()
        watchdog = hardLimit

        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: watchdogQueue)
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                // Independent fallback also bounds cancellation if the main thread is blocked.
                self.watchdogQueue.asyncAfter(deadline: .now() + .seconds(1)) {
                    Self.forcedExit(128 + signalNumber)
                }
                DispatchQueue.main.async { self.stop("signal_\(signalNumber)", code: 128 + signalNumber) }
            }
            source.resume()
            signals.append(source)
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: stopAt, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.stop("time_limit", code: 0) }
        timer.resume()
        deadline = timer

        guard emit(["event": "observation_start", "seconds": seconds,
                    "hard_exit_grace_seconds": 1, "service_identity": "unknown",
                    "directions": "any", "scope": "new_open_notifications_only",
                    "target_address_recorded": false]) else { return }
        // This is the first IOBluetooth API call. No device object is created or queried.
        openNotification = IOBluetoothRFCOMMChannel.register(forChannelOpenNotifications: self,
            selector: #selector(channelOpened(_:channel:)))
        guard openNotification != nil else { stop("open_notification_registration_failed", code: 3); return }
        _ = emit(["event": "open_notification_registered", "service_identity": "unknown"])
    }

    @objc private func channelOpened(_ notification: IOBluetoothUserNotification,
                                     channel: IOBluetoothRFCOMMChannel) {
        // Always enqueue, including synchronous registration callbacks, so registration
        // has returned before the token is inspected. All mutable state stays on main.
        DispatchQueue.main.async { [weak self] in self?.handleOpened(notification, channel: channel) }
    }

    private func handleOpened(_ notification: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        openCallbacksReceived += 1
        guard !stopping else { openCallbacksIgnoredAfterStop += 1; return }
        guard notification === openNotification else { openCallbacksTokenMismatch += 1; return }
        guard let channelAddress = normalizedAddress(channel.getDevice()?.addressString) else {
            openCallbacksAddressUnavailable += 1
            return
        }
        guard channelAddress == address else { openCallbacksAddressNotTarget += 1; return }
        openCallbacksTargetMatched += 1
        let objectID = channel.getObjectID()
        guard channels[objectID] == nil else { return }
        guard objectID != 0, channels.count < 128 else { stop("channel_tracking_limit_or_invalid_id", code: 3); return }
        nextObservationID += 1
        let tracked = TrackedChannel(observationID: nextObservationID)
        channels[objectID] = tracked
        guard emit(metadata(channel, event: "channel_open_notification", tracked: tracked)) else { return }
        tracked.notification = channel.register(forChannelCloseNotification: self,
            selector: #selector(channelClosed(_:channel:)))
        guard tracked.notification != nil else { stop("close_notification_registration_failed", code: 3); return }
        _ = emit(metadata(channel, event: "close_notification_registered", tracked: tracked))
    }

    @objc private func channelClosed(_ notification: IOBluetoothUserNotification,
                                     channel: IOBluetoothRFCOMMChannel) {
        DispatchQueue.main.async { [weak self] in self?.handleClosed(notification, channel: channel) }
    }

    private func handleClosed(_ notification: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        guard !stopping, let tracked = channels[channel.getObjectID()], tracked.notification === notification else { return }
        guard normalizedAddress(channel.getDevice()?.addressString) == address else {
            stop("close_notification_target_identity_unavailable", code: 3)
            return
        }
        guard emit(metadata(channel, event: "channel_close_notification", tracked: tracked)) else { return }
        // Only the notification is unregistered; no channel operation is requested.
        tracked.notification = nil
        notification.unregister()
        channels.removeValue(forKey: channel.getObjectID())
    }

    private func metadata(_ channel: IOBluetoothRFCOMMChannel, event: String, tracked: TrackedChannel) -> [String: Any] {
        ["event": event, "target_match": true, "observation_id": tracked.observationID,
         "channel_id": Int(channel.getID()), "is_incoming": channel.isIncoming(),
         "object_id": String(channel.getObjectID()), "is_open": channel.isOpen(),
         "service_identity": "unknown", "local_service_mapping": "unavailable"]
    }

    @discardableResult private func emit(_ fields: [String: Any]) -> Bool {
        do { try output.append(fields); return true }
        catch { stop("output_failed", code: 4, recordStop: false); return false }
    }

    private func stop(_ reason: String, code: Int32, recordStop: Bool = true) {
        guard !stopping else { return }
        stopping = true
        deadline?.cancel()
        let open = openNotification
        openNotification = nil
        open?.unregister()
        let registered = channels.values.compactMap(\.notification)
        channels.removeAll()
        for notification in registered { notification.unregister() }
        if recordStop {
            try? output.append(["event": "observation_stop", "reason": reason,
                                "notifications_unregistered": true,
                                "channel_close_notifications_removed": registered.count,
                                "target_channel_observations": nextObservationID,
                                "open_callback_counts": [
                                    "received": openCallbacksReceived,
                                    "ignored_after_stop": openCallbacksIgnoredAfterStop,
                                    "token_mismatch": openCallbacksTokenMismatch,
                                    "address_unavailable": openCallbacksAddressUnavailable,
                                    "address_not_target": openCallbacksAddressNotTarget,
                                    "target_matched": openCallbacksTargetMatched
                                ],
                                "service_identity": "unknown"])
        }
        output.finish()
        for source in signals { source.cancel() }
        watchdog?.cancel()
        exit(code)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
// Help wins even if other arguments are present. It cannot start observation.
if arguments.contains("--help") || arguments.contains("-h") { print(usage); exit(0) }
do {
    let options = try parseOptions(arguments)
    guard options.observe else {
        print("Preview only: no Bluetooth API calls, notifications or file writes.")
        print("Service identity remains unknown. Use --help for the explicit observation command.")
        exit(0)
    }
    let output = try PrivateJSONLines(path: options.output!)
    let observer = ChannelObserver(address: options.address!, seconds: options.seconds!, output: output)
    observer.start()
    withExtendedLifetime(observer) { RunLoop.main.run() }
} catch {
    fputs("mic2-channel-observer: \(error)\n", stderr)
    exit(2)
}
