import Foundation

// EventLogger — actor-owned ring buffer + multi-subscriber AsyncStream fan-out.
// See docs/mcp/EVENT_LOGGING.md. Default buffer size 512 per that doc; late
// subscribers do NOT replay the buffer — they only see events emitted after
// they subscribe (matches the Android SharedFlow replay=0 semantic).

public actor EventLogger {
    private var buffer: [RuntimeEvent] = []
    private let capacity: Int

    // Active fan-out continuations keyed by an opaque token so unsubscription
    // works without holding a reference to the closure.
    private var subscribers: [UUID: AsyncStream<RuntimeEvent>.Continuation] = [:]

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    /// Record an event into the ring buffer and fan out to all active subscribers.
    public func emit(_ event: RuntimeEvent) {
        if buffer.count >= capacity {
            buffer.removeFirst(buffer.count - capacity + 1)
        }
        buffer.append(event)
        for cont in subscribers.values {
            cont.yield(event)
        }
    }

    /// Snapshot of events currently held in the ring buffer (oldest first).
    public func snapshot() -> [RuntimeEvent] {
        buffer
    }

    public func bufferCount() -> Int {
        buffer.count
    }

    /// Open a new AsyncStream that receives every subsequent emit.
    /// The stream tears down automatically when the iterator is cancelled.
    public nonisolated func events() -> AsyncStream<RuntimeEvent> {
        AsyncStream { continuation in
            let token = UUID()
            let logger = self
            Task { await logger.register(token: token, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await logger.unregister(token: token) }
            }
        }
    }

    fileprivate func register(token: UUID, continuation: AsyncStream<RuntimeEvent>.Continuation) {
        subscribers[token] = continuation
    }

    fileprivate func unregister(token: UUID) {
        if let cont = subscribers.removeValue(forKey: token) {
            cont.finish()
        }
    }

    /// Cancel every subscriber — used during ExtentosGlasses.shutdown().
    public func drain() {
        for cont in subscribers.values {
            cont.finish()
        }
        subscribers.removeAll()
    }
}
