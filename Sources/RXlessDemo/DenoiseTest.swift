import Foundation
import MicLinkCore

/// One explicit button press runs version -> fresh settings -> write -> readback.
/// Never retries a write and never reconnects or alters audio routing.
final class DenoiseTest {
    private weak var session: MicSession?
    private let enabled: Bool
    private let finished: (String) -> Void
    private var original: Mic2AudioConfiguration?
    private var stage = 0
    private var completed = false
    private var writeAttempted = false
    private var timer: Timer?
    private let deadline = ProcessInfo.processInfo.systemUptime + 35

    init(session: MicSession, enabled: Bool, finished: @escaping (String) -> Void) {
        self.session = session; self.enabled = enabled; self.finished = finished
    }
    func start() {
        session?.queryCompleted = { [weak self] command, result in self?.received(command, result) }
        send(.version)
    }
    func cancel() { finish("降噪测试已结束") }
    private func finish(_ text: String) {
        guard !completed else { return }
        completed = true; timer?.invalidate(); timer = nil
        session?.queryCompleted = nil
        finished(text)
    }
    private func fail(_ text: String) {
        finish(text + (writeAttempted ? "；写入已尝试，请回读确认当前降噪设置" : "；未写入配置"))
    }
    private func send(_ command: MicControlCommand, configuration: Mic2AudioConfiguration? = nil) {
        guard !completed else { return }
        guard let session, !session.isClosing else { fail("SPP 已结束"); return }
        guard ProcessInfo.processInfo.systemUptime < deadline else { fail("降噪测试超时"); return }
        if !session.canQuery {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                self?.send(command, configuration: configuration)
            }
            return
        }
        do {
            if command == .denoiseOff || command == .denoiseOn { writeAttempted = true }
            try session.sendQuery(command, configuration: configuration)
        } catch { fail(error.localizedDescription) }
    }
    private func received(_ command: MicControlCommand, _ result: Result<[UInt8], Error>) {
        guard !completed else { return }
        do {
            let payload = try result.get()
            switch stage {
            case 0:
                guard command == .version, payload.count == 30,
                      Array(payload[22..<26]) == [31, 2, 5, 4] else {
                    throw StreamError.invalid("本轮仅适用于 TX 04.05.02.31")
                }
                stage = 1; send(.audioConfiguration)
            case 1:
                guard command == .audioConfiguration else { throw StreamError.invalid("配置应答不匹配") }
                let config = try Mic2AudioConfiguration(reply: payload)
                original = config
                if config.denoiseEnabled == enabled {
                    finish("回读确认：降噪已\(enabled ? "开启" : "关闭")，无需写入；SPP 保持连接")
                    return
                }
                // Validate all fields before attempting a transport write.
                _ = try config.denoiseWritePayload(enabled: enabled)
                stage = 2; send(enabled ? .denoiseOn : .denoiseOff, configuration: config)
            case 2:
                guard command == (enabled ? .denoiseOn : .denoiseOff), payload == [0] else {
                    throw StreamError.invalid("降噪设置应答不匹配")
                }
                stage = 3; send(.audioConfiguration)
            case 3:
                guard command == .audioConfiguration, let original else { throw StreamError.invalid("回读应答不匹配") }
                let config = try Mic2AudioConfiguration(reply: payload)
                guard config.matches(original, denoiseEnabled: enabled) else {
                    throw StreamError.invalid("回读配置与预期不同")
                }
                finish("降噪已\(enabled ? "开启" : "关闭") · ACK 00 / 回读一致 · 其他设置保持 · SPP 保持连接")
            default: break
            }
        } catch { fail(error.localizedDescription) }
    }
    deinit { timer?.invalidate() }
}
