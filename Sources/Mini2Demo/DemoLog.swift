import Foundation
import Combine

final class DemoLog: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var error: String?
    let directory: URL
    private var handle: FileHandle?
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("MicBridge Mini 2 Demo/Sessions/\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("events.jsonl")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: url)
        } catch { self.error = "日志文件无法创建：\(error.localizedDescription)" }
    }
    func add(_ message: String, fields: [String: Any] = [:]) {
        let clock = Date().formatted(date: .omitted, time: .standard)
        lines.append("\(clock)  \(message)")
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        var event = fields
        event["time"] = ISO8601DateFormatter().string(from: Date()); event["message"] = message
        do {
            var bytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            bytes.append(10); try handle?.write(contentsOf: bytes)
        } catch { self.error = "日志写入失败：\(error.localizedDescription)"; handle = nil }
    }
    deinit { try? handle?.close() }
}
