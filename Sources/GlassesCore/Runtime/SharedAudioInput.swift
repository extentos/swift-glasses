import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

// Single-tap fan-out on `AVAudioEngine.inputNode`. Multiple consumers
// subscribe (audio_chunks readers, SFSpeech recognition request,
// record_audio writer, capture_video audio writer); the tap is installed
// on the first subscribe and removed when the last consumer unsubscribes.
//
// Apple lets only one tap exist per (node, bus). Without this fan-out,
// audio_chunks installing a tap and `transcriptions()` trying to install
// another would crash on the second `installTap`. See PHASE_6_PLAN.md §5.6.
//
// `@unchecked Sendable` because consumer storage is guarded by NSLock and
// the AVAudioPCMBuffer hand-off in the tap callback runs synchronously on
// the audio thread (handlers must finish before returning so the buffer
// stays valid). Audio session configuration is iOS-specific and injected
// by the caller via `configureSession` / `teardownSession`.

#if canImport(AVFAudio)

/// Test seam over `SharedAudioInput`. Production uses the
/// `AVAudioEngine`-backed concrete class below; unit tests can pass a
/// no-op implementation so PlatformSttEngine doesn't try to spin up a
/// real audio engine on a headless macOS test host.
protocol AudioInputSubscribing: AnyObject, Sendable {
    typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void
    func subscribe(_ handler: @escaping BufferHandler) -> UUID?
    func unsubscribe(_ id: UUID)
    /// The live input format while the engine runs, else nil. Consumers
    /// that must declare a track format up-front (the video AAC track)
    /// subscribe first — which spins the engine up — then read this.
    func currentFormat() -> AVAudioFormat?
}

extension AudioInputSubscribing {
    func currentFormat() -> AVAudioFormat? { nil }
}

final class SharedAudioInput: AudioInputSubscribing, @unchecked Sendable {
    typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    /// Rebuild debounce: SCO/route negotiation fires configuration changes
    /// in bursts; one rebuild after a short settle beats one per
    /// notification (doc 18 §D).
    static let rebuildSettleMs = 300
    static let rebuildRetryMs = 1_000

    private let lock = NSLock()
    private var consumers: [UUID: BufferHandler] = [:]
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var rebuildScheduled = false
    private let configureSession: () throws -> Void
    private let teardownSession: () -> Void

    init(
        configureSession: @escaping () throws -> Void = {},
        teardownSession: @escaping () -> Void = {}
    ) {
        self.configureSession = configureSession
        self.teardownSession = teardownSession
    }

    /// The buffer format the tap is currently configured with, or nil if
    /// the engine isn't running. Safe to call from any thread.
    func currentFormat() -> AVAudioFormat? {
        lock.lock(); defer { lock.unlock() }
        return engine?.inputNode.outputFormat(forBus: 0)
    }

    /// Register a buffer consumer. Returns the subscription id so the
    /// caller can unsubscribe later. Returns nil if engine setup failed
    /// (audio session denied, hardware unavailable).
    func subscribe(_ handler: @escaping BufferHandler) -> UUID? {
        let id = UUID()
        lock.lock()
        let needsStart = engine == nil
        consumers[id] = handler
        lock.unlock()
        if needsStart {
            do {
                try ensureRunning()
            } catch {
                lock.lock()
                consumers.removeValue(forKey: id)
                lock.unlock()
                return nil
            }
        }
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock()
        consumers.removeValue(forKey: id)
        let shouldStop = consumers.isEmpty
        lock.unlock()
        if shouldStop {
            tearDown()
        }
    }

    private func ensureRunning() throws {
        try configureSession()
        let e = AVAudioEngine()
        let input = e.inputNode
        // Acoustic echo cancellation, and it must happen HERE — before the
        // format is read and before the tap goes on.
        //
        // `AVAudioSession`'s `.voiceChat` mode states the intent; it does not
        // engage the Voice-Processing I/O unit for an `AVAudioEngine`. Only
        // this call does. Without it the mic hears whatever the device plays,
        // which was harmless while output sat on the earpiece — near-zero
        // acoustic coupling — and became a feedback loop the moment
        // `.defaultToSpeaker` put the assistant on the loudspeaker: it heard
        // itself, transcribed itself, and answered itself.
        //
        // Deliberately NOT solved by gating the mic while speaking: that would
        // kill barge-in, which is a designed primitive here. VPIO subtracts the
        // device's OWN output from the input, so a real interruption still
        // arrives intact — the echo is what disappears.
        //
        // Best-effort: a platform that refuses it (some simulators) keeps
        // capturing without cancellation rather than losing the microphone.
        // Order matters — VPIO changes the input format, so read it after.
        var aec = false
        do {
            try input.setVoiceProcessingEnabled(true)
            aec = true
        } catch {
            WakeLedger.shared.note("audio: voice processing UNAVAILABLE (\(error))")
        }
        let format = input.outputFormat(forBus: 0)
        // Tap callback runs on a dedicated audio render thread. Snapshot
        // the consumer list under lock, then dispatch synchronously so the
        // buffer reference stays valid for every handler.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.lock.lock()
            let snapshot = Array(self.consumers.values)
            self.lock.unlock()
            for handler in snapshot {
                handler(buffer, when)
            }
        }
        try e.start()
        lock.lock()
        engine = e
        lock.unlock()
        installObservers(for: e)
        WakeLedger.shared.note(String(
            format: "audio: engine started (%.0fHz ch%d) aec=%@",
            format.sampleRate, format.channelCount, aec ? "on" : "OFF"
        ))
    }

    // ── Event-driven engine recovery (doc 18 §D — the fix for the
    //    "subscription alive, tap dead" launch race) ─────────────────────
    //
    // AVAudioEngine can stop without restarting when the audio graph
    // changes under it — and the glasses' Bluetooth HFP/SCO negotiation
    // right after app launch is exactly such a change (measured: ~40 s of
    // zero buffers on the b17 run; the b16-era first-wake failures). iOS
    // announces every such change; reacting to the announcement replaces
    // the retired silence-polling watchdog. Subscriber registrations
    // survive a rebuild by construction — only the engine + tap recycle.

    private func installObservers(for engine: AVAudioEngine) {
        removeObservers()
        var obs: [NSObjectProtocol] = []
        let center = NotificationCenter.default
        obs.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.scheduleRebuild(reason: "engine configuration change")
        })
        #if os(iOS)
        obs.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            self?.scheduleRebuild(reason: "interruption ended")
        })
        #endif
        lock.lock()
        observers = obs
        lock.unlock()
    }

    private func removeObservers() {
        lock.lock()
        let obs = observers
        observers = []
        lock.unlock()
        for o in obs { NotificationCenter.default.removeObserver(o) }
    }

    private func scheduleRebuild(reason: String) {
        lock.lock()
        let wanted = !consumers.isEmpty && !rebuildScheduled
        if wanted { rebuildScheduled = true }
        lock.unlock()
        guard wanted else { return }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(Self.rebuildSettleMs)
        ) { [weak self] in
            self?.performRebuild(reason: reason)
        }
    }

    private func performRebuild(reason: String) {
        lock.lock()
        rebuildScheduled = false
        let e = engine
        engine = nil
        let hasConsumers = !consumers.isEmpty
        lock.unlock()
        removeObservers()
        if let e {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        guard hasConsumers else {
            teardownSession()
            return
        }
        LocalTierDiagnostics.shared.record("audio: input engine rebuilt (\(reason))")
        WakeLedger.shared.note("audio: engine rebuild (\(reason))")
        do {
            // Re-activates the session too — idempotent, and after a route
            // change the fresh activation is the point.
            try ensureRunning()
        } catch {
            // Activation right after a route change can throw and succeed
            // moments later (2026-07-15 hardware finding) — keep retrying
            // at ~1 Hz while consumers exist (mirrors PlatformSttEngine's
            // input-retry posture; genuinely-terminal causes idle-spin).
            NSLog("[Extentos] audio input rebuild failed (%@): %@", reason, String(describing: error))
            WakeLedger.shared.note("audio: engine rebuild FAILED (\(error))")
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(Self.rebuildRetryMs)
            ) { [weak self] in
                self?.scheduleRebuild(reason: "\(reason) — retry")
            }
        }
    }

    private func tearDown() {
        removeObservers()
        lock.lock()
        let e = engine
        engine = nil
        lock.unlock()
        if let e {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        teardownSession()
    }
}

#endif // canImport(AVFAudio)
