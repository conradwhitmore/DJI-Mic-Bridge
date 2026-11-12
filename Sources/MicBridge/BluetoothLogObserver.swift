import Foundation
import MicBridgeSupport

/// Read-only live logs. No history replay, elevated privileges, Bluetooth calls or audio I/O.
final class BluetoothLogObserver {
    var onEvent: ((BluetoothModeEvent, Date) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    private let queue = DispatchQueue(label: "MicBridge.bluetooth-log-reader", qos: .utility)
    private var task: Process?
    private var output: Pipe?
    private var buffer = Data()
    private var bufferToken: UUID?
    private var generation = UUID()
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"; return f
    }()
    func start(target: String) {
        stop()
        guard !target.isEmpty else { onStatus?("未选择设备，蓝牙日志监听已停止", false); return }
        let token = UUID(); generation = token
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        // Broad enough for boundary events; only exact selected-address matches leave this reader.
        let predicate = "process == 'bluetoothd' AND (eventMessage BEGINSWITH 'Creating HFPAudioDevice for device ' OR eventMessage BEGINSWITH 'Received voice audio connected event for device ' OR eventMessage BEGINSWITH 'Received voice disconnection event for device ' OR eventMessage BEGINSWITH 'ACL connected:' OR eventMessage BEGINSWITH 'ACL disconnected:')"
        process.arguments = ["stream", "--style", "ndjson", "--level", "info", "--predicate", predicate]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        output = pipe; task = process
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in self?.consume(bytes, target: target, token: token) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.onStatus?("蓝牙日志不可用，继续使用系统音频属性判断", false)
            }
        }
        do { try process.run(); onStatus?("正在监听新事件；未匹配或脱敏日志不作模式依据", true) }
        catch { stop(); onStatus?("无法读取蓝牙日志，继续使用系统音频属性判断", false) }
    }
    private func consume(_ data: Data, target: String, token: UUID) {
        // Serial queue owns framing; main queue owns lifecycle and delivery checks.
        if bufferToken != token { buffer.removeAll(); bufferToken = token }
        buffer.append(data)
        if buffer.count > 1_048_576 { buffer.removeAll(); reportGap(token: token); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if (row["eventType"] as? String)?.lowercased().contains("loss") == true {
                reportGap(token: token); continue
            }
            guard row["processImagePath"] as? String == "/usr/sbin/bluetoothd",
                  let message = row["eventMessage"] as? String,
                  let stamp = row["timestamp"] as? String, let date = formatter.date(from: stamp),
                  let event = BluetoothModeEvent.parse(message, target: target) else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.onStatus?("正在监听新事件；已匹配当前设备地址", true)
                self.onEvent?(event, date)
            }
        }
    }
    private func reportGap(token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.onStatus?("日志出现缺口，等待新的设备证据；继续读取系统音频属性", false)
        }
    }
    func stop() {
        generation = UUID()
        output?.fileHandleForReading.readabilityHandler = nil
        if let task, task.isRunning { task.terminate() }
        task = nil; output = nil
        queue.async { [weak self] in self?.buffer.removeAll() }
    }
    deinit { output?.fileHandleForReading.readabilityHandler = nil; if task?.isRunning == true { task?.terminate() } }
}
