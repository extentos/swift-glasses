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

    private let lock = NSLock()
    private var consumers: [UUID: BufferHandler] = [:]
    private var engine: AVAudioEngine?
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
        let format = input.outputFormat(forBus: 0)
        // Tap callback runs on a dedicated audio render thread. Snapshot
        // the consumer list under lock, then dispatch synchronously so the
        // buffer reference stays valid for every handler.
        //
        // KNOWN LIMITATION: this class does NOT observe
        // `AVAudioEngineConfigurationChange` notifications. If the audio
        // route changes mid-tap (user pulls AirPods, plugs in a headset,
        // takes a call) AVAudioEngine may stop without restarting. The
        // PlatformSttEngine's recoverable-error path will catch the STT
        // side via SFSpeechRecognizer's error stream and restart the
        // recognizer, but the underlying tap stays dead. Smoke test 6
        // (PHASE_6_PLAN.md §7.3) catches this — fix is to add a
        // NotificationCenter observer on `.AVAudioEngineConfigurationChange`
        // that tears down + reinstalls the tap. Sprint 5 / follow-up.
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
    }

    private func tearDown() {
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
