import Foundation

/// Coordinates one asynchronous open request and its eventual close.
/// Call every method on the same queue. Channel IDs must identify object instances,
/// and `now` must use one consistent clock. No channel or hardware API is used here.
public final class RFCOMMCloseCoordinator {
    public enum Outcome: Equatable {
        case notOpened, confirmed, unconfirmed
    }

    private enum OpeningState {
        case notStarted, pending, failed, succeeded
    }

    private struct Channel {
        var opened = false
        var closed = false
        var cancellationRequested = false
        var closeAfterOpenRequested = false
    }

    private let timeout: TimeInterval
    private let requestClose: (UInt64) -> Int32
    private let onOutcome: (Outcome) -> Void
    private var opening: OpeningState = .notStarted
    private var channels: [UInt64: Channel] = [:]
    private var successWithoutChannel = false
    private var stopping = false
    private var deadline: TimeInterval?
    private var outcome: Outcome?

    public init(timeout: TimeInterval = 8,
                requestClose: @escaping (UInt64) -> Int32,
                onOutcome: @escaping (Outcome) -> Void) {
        self.timeout = max(0, timeout)
        self.requestClose = requestClose
        self.onOutcome = onOutcome
    }

    public func openingStarted() {
        guard opening == .notStarted else { return }
        opening = .pending
    }

    public func openingRequestFailed() {
        openingFailed()
    }

    public func channelAvailable(id: UInt64) {
        if opening == .notStarted { opening = .pending }
        var channel = channels[id] ?? Channel()
        if successWithoutChannel {
            if !channel.opened {
                channel.opened = true
                channel.closed = false
            }
            successWithoutChannel = false
        } else if opening == .failed && !channel.opened {
            channel.closed = true
        }
        channels[id] = channel
        closeIfNeeded(id: id)
        confirmIfFinished()
    }

    public func openingCompleted(id: UInt64?, success: Bool) {
        guard success else {
            if let id, channels[id] == nil { channels[id] = Channel() }
            openingFailed()
            return
        }

        // A success is still actionable after cancellation, timeout, or a prior
        // failure. Repeated success notifications must not reopen a closed ID.
        let firstSuccess = opening != .succeeded
        opening = .succeeded
        if let id {
            var channel = channels[id] ?? Channel()
            if !channel.opened {
                channel.opened = true
                channel.closed = false
            }
            channels[id] = channel
            successWithoutChannel = false
            closeIfNeeded(id: id)
        } else if firstSuccess {
            // A successful open with no usable identity cannot be confirmed
            // closed until a channel becomes available and reports closure.
            successWithoutChannel = true
        }
        confirmIfFinished()
    }

    public func channelClosed(id: UInt64) {
        var channel = channels[id] ?? Channel()
        channel.closed = true
        channels[id] = channel
        confirmIfFinished()
    }

    public func stop(now: TimeInterval) {
        guard !stopping else { return }
        stopping = true
        deadline = now + timeout
        for id in channels.keys.sorted() { closeIfNeeded(id: id) }
        tick(now: now)
    }

    public func tick(now: TimeInterval) {
        guard stopping, outcome == nil else { return }
        confirmIfFinished()
        if outcome == nil, let deadline, now >= deadline {
            report(.unconfirmed)
        }
    }

    private func openingFailed() {
        // Failure terminates pending objects, but never overrides a known open.
        if opening != .succeeded { opening = .failed }
        for id in Array(channels.keys) where channels[id]?.opened == false {
            channels[id]?.closed = true
        }
        confirmIfFinished()
    }

    private func closeIfNeeded(id: UInt64) {
        guard stopping, var channel = channels[id], !channel.closed else { return }
        if channel.opened {
            guard !channel.closeAfterOpenRequested else { return }
            channel.closeAfterOpenRequested = true
        } else {
            guard !channel.cancellationRequested else { return }
            channel.cancellationRequested = true
        }
        // Commit before calling out: close may synchronously deliver either a
        // closed callback or a late successful open, which may need one more close.
        channels[id] = channel
        _ = requestClose(id)
        // Even a zero return only acknowledges the request, not channel closure.
    }

    private func confirmIfFinished() {
        guard stopping, outcome == nil else { return }
        if opening == .notStarted {
            report(.notOpened)
        } else if opening != .pending && !successWithoutChannel
                    && channels.values.allSatisfy({ $0.closed }) {
            report(.confirmed)
        }
    }

    private func report(_ result: Outcome) {
        guard outcome == nil else { return }
        outcome = result
        onOutcome(result)
    }
}
