import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation)

/// AVSpeechSynthesizerDelegate bridge from the synthesizer's
/// `didFinish` / `didCancel` callbacks back to the `await speak()`
/// continuation.
///
/// Pre-fix (Option-1 of `shared-context/ios-speech-delegate-fix-handoff.md`)
/// the box held a single `onFinish` closure that the next `speak()` call
/// overwrote. Two utterances overlapping — back-to-back speaks, or a
/// cancel-then-speak where the new continuation lands before the prior
/// `didCancel` callback — silently lost the prior continuation: the
/// `await speak("first")` hung forever even though the audio actually
/// played to completion on the speaker.
///
/// The fix: keep a per-utterance map keyed by `ObjectIdentifier`. Each
/// `register(...)` slots a continuation in for its own utterance. When
/// `didFinish` or `didCancel` fires, the box looks up the continuation
/// by the utterance the synthesizer hands back and resumes only that
/// one. Multiple in-flight utterances each have their own slot; no
/// overwrite is possible.
///
/// `internal` (not `private`/scoped to RealMetaTransport) so the unit
/// tests in `Tests/GlassesCoreTests/SpeechDelegateBoxTests.swift` can
/// drive the callbacks directly without spinning up the full
/// MWDAT-gated `RealMetaTransport` actor (which is `#if os(iOS)`-only
/// and unreachable from the macOS `swift test` host).
///
/// Hoisted out of `RealMetaTransport.swift` for that same testability
/// reason — `AVSpeechSynthesizer{,Delegate,Utterance}` are part of
/// AVFoundation, available on iOS + macOS, so this file compiles on
/// both targets even though `RealMetaTransport` does not.
internal final class SpeechDelegateBox: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

    /// Register a continuation for `utterance`. Called from inside
    /// `withCheckedContinuation { … }` in `speak()` before handing the
    /// utterance to the synthesizer. The continuation will resume on
    /// the next `didFinish` / `didCancel` callback for this utterance.
    func register(_ utterance: AVSpeechUtterance, continuation: CheckedContinuation<Void, Never>) {
        let key = ObjectIdentifier(utterance)
        let prior: CheckedContinuation<Void, Never>?
        lock.lock()
        prior = continuations.removeValue(forKey: key)
        continuations[key] = continuation
        lock.unlock()
        // Same-utterance re-register: shouldn't happen in practice (each
        // `speak()` call constructs a fresh AVSpeechUtterance instance),
        // but if it does, resolve the prior continuation so its caller
        // doesn't hang. Resolving outside the lock per Swift's standard
        // continuation-resume contract.
        prior?.resume(returning: ())
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(utterance)
    }

    private func complete(_ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        let cont: CheckedContinuation<Void, Never>?
        lock.lock()
        cont = continuations.removeValue(forKey: key)
        lock.unlock()
        // Unknown utterances are a no-op — `complete` is idempotent for
        // utterances that never registered (or already resolved). This
        // matters when `stopSpeaking(.immediate)` fires `didCancel` for
        // queued-but-not-started utterances the host code never awaited.
        cont?.resume(returning: ())
    }

    #if DEBUG
    /// Test-only inspection — current pending-continuation count.
    /// Used by `SpeechDelegateBoxTests` to assert the map drains after
    /// each completion.
    internal var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return continuations.count
    }
    #endif
}

#endif // canImport(AVFoundation)
