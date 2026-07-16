import Foundation

// PushToTalkSession + AudioClient.startPushToTalk — push-to-talk
// helper for host apps. Mirrors `android-library/.../PushToTalkSession.kt`.
//
// Audio comes from the glasses side via AudioClient.transcriptions().
// What every push-to-talk handler had to write was the same subscribe /
// accumulate Final / cancel-and-flush boilerplate. This helper bundles
// that lifecycle so a UI handler reads:
//
//   // onPress
//   session = glasses.audio.startPushToTalk()
//
//   // onRelease (Task)
//   let text = await session.stopAndFlush()
//   // hand `text` to the host app's prompt / dispatch / etc.
//
// Audio source is unchanged — still glasses-side via transcriptions().
// Only the lifecycle wrapping is new.

/// Single in-flight push-to-talk capture. Created via
/// `AudioClient.startPushToTalk`; ended via `stopAndFlush()`.
public final class PushToTalkSession: @unchecked Sendable {
    private let task: Task<Void, Never>
    private let store: TranscriptStore
    private let stoppedLock = NSLock()
    private var stopped = false

    fileprivate init(task: Task<Void, Never>, store: TranscriptStore) {
        self.task = task
        self.store = store
    }

    /// Cancel the underlying transcription subscription and return the
    /// concatenated text of every Final transcript received during the
    /// session. Idempotent — calling twice returns the same string.
    public func stopAndFlush() async -> String {
        let alreadyStopped: Bool = stoppedLock.withLock {
            let was = stopped
            stopped = true
            return was
        }
        if !alreadyStopped {
            task.cancel()
            // Wait for the collector Task to actually exit so a Final
            // emitted concurrently with cancellation doesn't race the
            // snapshot read.
            _ = await task.value
        }
        return await store.snapshot()
    }
}

internal actor TranscriptStore {
    private var parts: [String] = []
    func append(_ s: String) { parts.append(s) }
    func snapshot() -> String {
        parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public extension AudioClient {
    /// Begin a push-to-talk capture. Subscribes to
    /// `transcriptions(config:)` and accumulates Final transcripts. The
    /// returned `PushToTalkSession` is the only handle the caller needs;
    /// `stopAndFlush()` ends the capture and returns the joined text.
    func startPushToTalk(
        config: TranscriptionConfig = TranscriptionConfig(language: "en-US", partial: false)
    ) -> PushToTalkSession {
        let store = TranscriptStore()
        let stream = transcriptions(config: config)
        let task = Task { [stream, store] in
            for await transcript in stream {
                if Task.isCancelled { return }
                if case .final(let text, _, _, _) = transcript {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        await store.append(trimmed)
                    }
                }
            }
        }
        return PushToTalkSession(task: task, store: store)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
