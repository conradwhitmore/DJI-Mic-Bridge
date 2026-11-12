import Foundation
import MicLinkCore

/// Explicit, one-shot workflow. Enter checks version and idle local recording;
/// exit is always available without version/config queries for recovery.
final class KeyTestOperation {
    private weak var session: MicSession?
    private let enabled: Bool
    private let finished: (Bool, String) -> Void
    private var stage = 0
    private var done = false
    private var timer: Timer?
    private let deadline = ProcessInfo.processInfo.systemUptime + 30
    init(session: MicSession, enabled: Bool, finished: @escaping (Bool, String) -> Void) {
        self.session = session; self.enabled = enabled; self.finished = finished
    }
    func start() {
        session?.queryCompleted = { [weak self] command, result in self?.received(command, result) }
        if enabled { send(.version) }
        else { stage = 2; send(.keyTestOff) }
    }
    func cancel() { finish(false, "连接结束；按键测试模式状态未确认") }
    private func finish(_ success: Bool, _ message: String) {
        guard !done else { return }
        done = true; timer?.invalidate(); timer = nil
        session?.queryCompleted = nil
        finished(success, message)
    }
    private func send(_ command: MicControlCommand) {
        guard !done else { return }
        guard let session, !session.isClosing else { finish(false, "SPP 已结束"); return }
        guard ProcessInfo.processInfo.systemUptime < deadline else { finish(false, "按键测试请求超时，可点击退出按键测试恢复"); return }
        let ready = command == .keyTestOff ? session.canRecoverKeyTest : session.canQuery
        guard ready else {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in self?.send(command) }
            return
        }
        do { try session.sendQuery(command) }
        catch { finish(false, error.localizedDescription) }
    }
    private func received(_ command: MicControlCommand, _ result: Result<[UInt8], Error>) {
        guard !done else { return }
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
                _ = try Mic2AudioConfiguration(reply: payload)
                guard payload[18] & 1 == 0 else { throw StreamError.invalid("请先停止 Mic 2 本地录音") }
                stage = 2; send(.keyTestOn)
            default:
                guard command == (enabled ? .keyTestOn : .keyTestOff) else { throw StreamError.invalid("按键测试应答不匹配") }
                finish(true, enabled ? "已进入按键测试 · 请短按，观察 04/68 独立事件" : "已退出按键测试 · ACK 00，恢复普通按键功能")
            }
        } catch { finish(false, error.localizedDescription) }
    }
    deinit { timer?.invalidate() }
}
