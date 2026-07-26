// Segmenter-arc rollout plumbing (step 2; doc 15's flags-first rule).
//
// The Rust deciders (EndpointDecider / SpeechRunTracker) ship DARK: their
// constants are b16-quiet-room provisional, and the b11 rule — no ears
// threshold ships without measured glasses numbers — keeps them off until
// the noisy-room tape locks calibration. The tape recorder defaults ON:
// it IS the measurement, and collecting that tape is the next hardware
// run's whole purpose (levels/timing shape only, never transcript text).

import Foundation

enum EarsTuning {
    /// Two-tier shaped-patience endpointing (Rust `EndpointDecider`)
    /// instead of the fixed 900 ms window.
    nonisolated(unsafe) static var shapedEndpointing = false
    /// RMS-onset barge-in (`SpeechRunTracker` → InterruptionClassifier →
    /// machine `SpeechStarted`; the machine's false-interruption resume
    /// owns the retract path). ENABLED 2026-07-23 after tape-replay
    /// calibration: 0 false onsets in 56 fired runs across the b17/b19/b21
    /// tapes at threshold 0.012 — and the provider additionally gates it
    /// to agent-SPEAKING only (THINKING keeps the transcript gate).
    nonisolated(unsafe) static var onsetBargeIn = true
    /// Ears tape recorder (`EarsTape`, NDJSON) for offline decider replay.
    nonisolated(unsafe) static var tapeRecorder = true
}

/// Internal bridge from the ears engine (which owns the mic tap and the
/// speech-run tracker) to the local provider (which owns the classifier
/// and the machine). Raw durations cross; ALL decisions live Rust-side.
final class EarsActivityHub: @unchecked Sendable {
    static let shared = EarsActivityHub()

    private let lock = NSLock()
    private var listener: (@Sendable (_ runMs: UInt32) -> Void)?

    func setListener(_ l: (@Sendable (_ runMs: UInt32) -> Void)?) {
        lock.lock()
        listener = l
        lock.unlock()
    }

    /// Posted per audio buffer while onset tracking is enabled: the current
    /// speech-run duration, 0 when silent (the run-end edge listeners use
    /// to re-arm).
    func postSpeechRun(_ runMs: UInt32) {
        lock.lock()
        let l = listener
        lock.unlock()
        l?(runMs)
    }
}
