import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(Speech)
import Speech
#endif

// PlatformSttEngine — continuous SFSpeechRecognizer loop with auto-restart
// after each final result. Owns the SFSpeechAudioBufferRecognitionRequest
// and the SFSpeechRecognitionTask; subscribes to a SharedAudioInput for
// PCM buffers so the engine's lifecycle is decoupled from the audio
// session and from any other mic consumer.
//
// Decisions locked in PHASE_6_PLAN.md §4:
//   §4.2 — platform default = online server-side; do NOT set
//          `requiresOnDeviceRecognition`.
//   §4.3 — auto-restart after each final result with a 300ms delay
//          (gives AVAudioEngine time to settle between recognition tasks).
//   §4.4 — iOS first.
//
// Test strategy: `SttSessionFactory` protocol seam lets unit tests inject
// a fake session that emits canned partial / final / error sequences
// without touching SFSpeechRecognizer. Production code uses the
// `SystemSttSessionFactory` impl below.

#if canImport(AVFAudio)

@MainActor
final class PlatformSttEngine {
    static let restartDelayMs: Int = 300

    // Shell-side utterance endpointing (2026-07-15 hardware finding).
    // SFSpeechRecognizer in buffer mode does NOT endpoint on silence: with a
    // continuous feed it grows one partial forever and `isFinal` never
    // arrives — so VoiceCore (which matches wake phrases on FINALs only)
    // never fires. Android's Vosk endpoints inside the engine; here WE own
    // the PCM stream, so the shell detects `silenceEndpointMs` of
    // post-speech silence and calls `session.finishAudio()` (endAudio) —
    // Apple then delivers the FINAL and the existing §4.3 restart loop
    // begins the next utterance.
    static let silenceEndpointMs: Int64 = 900
    static let speechRmsThreshold: Double = 0.012
    // Liveness backstop: endAudio() is documented to end the task with a
    // final result (or an error). If neither lands, recycle the session so
    // wake listening can't silently dead-end.
    static let finalBackstopMs: Int64 = 4000
    // Retry cadence when the shared audio input can't be subscribed
    // (AVAudioSession activation race at app launch).
    static let inputRetryDelayMs: Int = 1000

    private let audioInput: any AudioInputSubscribing
    private let factory: any SttSessionFactory

    private var session: (any SttSession)?
    private var bufferSubscriptionId: UUID?
    private var pendingConfig: TranscriptionConfig?
    private var onTranscript: ((Transcript) -> Void)?
    private var onError: ((Error) -> Void)?
    private var stopped: Bool = false
    private var restartScheduled: Bool = false

    // Endpointer state — main-actor only, reset per recognition session.
    private var utteranceHadSpeech: Bool = false
    private var lastSpeechAtMs: Int64 = 0
    private var finishRequestedAtMs: Int64?

    init(audioInput: any AudioInputSubscribing, factory: any SttSessionFactory) {
        self.audioInput = audioInput
        self.factory = factory
    }

    /// Begin a continuous recognition loop. The handler closures are
    /// invoked on the main actor. The returned `SttEngineHandle` stops
    /// recognition + tears down the audio subscription on `close()`.
    ///
    /// Triggers the system Speech Recognition authorization prompt on
    /// first call if status is `.notDetermined`. If the user denies, the
    /// engine reports `SttError.permissionDenied` via `onError` and
    /// stops; otherwise it proceeds to subscribe to the audio input.
    func start(
        config: TranscriptionConfig,
        onTranscript: @escaping (Transcript) -> Void,
        onError: @escaping (Error) -> Void
    ) -> SttEngineHandle {
        self.pendingConfig = config
        self.onTranscript = onTranscript
        self.onError = onError
        self.stopped = false
        Self.ensureAuthorized { [weak self] authorized in
            Task { @MainActor in
                guard let self else { return }
                if authorized {
                    self.startSession()
                } else {
                    self.onError?(SttError.permissionDenied)
                }
            }
        }
        let weakSelf = WeakBox(self)
        return SttEngineHandle {
            Task { @MainActor in weakSelf.value?.invalidate() }
        }
    }

    /// Wraps `SFSpeechRecognizer.requestAuthorization` (or the test-time
    /// override) so callers don't need to import Speech themselves. Safe
    /// to call any number of times — `requestAuthorization` is a no-op
    /// after the first determined status.
    private static func ensureAuthorized(_ completion: @escaping (Bool) -> Void) {
        if let override = authorizationOverride {
            completion(override())
            return
        }
        #if canImport(Speech)
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
        #else
        completion(false)
        #endif
    }

    /// Test seam: when set, `ensureAuthorized` returns the override's
    /// value instead of prompting. Tests inject `{ true }` so the mock
    /// session factory runs without UI.
    nonisolated(unsafe) static var authorizationOverride: (() -> Bool)?

    /// Stop recognition immediately and unsubscribe from the audio input.
    /// Idempotent.
    func invalidate() {
        stopped = true
        teardownSession()
    }

    // MARK: - Internals

    private func startSession() {
        guard !stopped, let config = pendingConfig else { return }

        // Fresh endpointer per recognition session.
        utteranceHadSpeech = false
        lastSpeechAtMs = 0
        finishRequestedAtMs = nil

        // Subscribe to the shared audio input *before* starting the
        // recognition session so we never lose the first buffers — the
        // tap thread will route them straight into request.append once
        // session is non-nil. The subscription is made ONCE and held
        // across recognition restarts (see teardownRecognition): it is
        // the engine's continuous mic stream, Vosk-parity with Android.
        if bufferSubscriptionId == nil {
            let id = audioInput.subscribe { [weak self] buffer, _ in
                guard let self else { return }
                // Crossing thread boundary: the tap callback runs on the
                // audio render thread; SttSession.append must be safe to call
                // from there. SFSpeechAudioBufferRecognitionRequest.append is
                // documented thread-safe, so we don't hop to the main actor.
                // RMS is computed on the render thread (the buffer must not
                // outlive the callback); only the scalar crosses the hop.
                let rms = Self.rms(of: buffer)
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                Task { @MainActor in
                    self.session?.append(buffer)
                    self.endpointTick(rms: rms, nowMs: nowMs)
                }
            }
            guard let id else {
                // Audio-input subscribe failed — the AVAudioSession activation
                // (or engine start) threw. At app launch this is a transient
                // race (2026-07-15 hardware finding: first run after install
                // failed here, killing wake until a manual toggle cycle;
                // activation succeeded moments later). Treat it like Android's
                // engine relaunch loop treats a hiccup: retry, don't die.
                // Genuinely-terminal causes (mic permission revoked, no input
                // hardware) keep failing here and just keep the retry loop
                // idle-spinning at 1Hz.
                scheduleInputRetry()
                return
            }
            bufferSubscriptionId = id
        }

        let s = factory.makeSession(
            config: config,
            onPartial: { [weak self] text, confidence in
                guard let self else { return }
                self.onTranscript?(.partial(text: text, confidence: Double(confidence)))
            },
            onFinal: { [weak self] text, startMs, endMs, confidence in
                guard let self else { return }
                self.finishRequestedAtMs = nil
                self.onTranscript?(.final(
                    text: text,
                    confidence: Double(confidence),
                    startMs: startMs,
                    endMs: endMs
                ))
                self.scheduleRestart()
            },
            onError: { [weak self] error in
                guard let self else { return }
                if Self.isRecoverable(error) {
                    self.scheduleRestart()
                } else {
                    self.onError?(error)
                    self.invalidate()
                }
            }
        )
        guard let s else {
            if let id = bufferSubscriptionId {
                audioInput.unsubscribe(id)
                bufferSubscriptionId = nil
            }
            onError?(SttError.recognizerUnavailable)
            return
        }
        session = s
    }

    /// Recycle ONLY the recognition session; the mic subscription stays.
    /// Tearing the subscription down per restart collapsed SharedAudioInput
    /// to zero consumers whenever STT was the sole mic user (assistant
    /// dormant) → full AVAudioSession deactivate/reactivate on EVERY
    /// utterance final → Bluetooth SCO re-negotiation → the glasses played
    /// their link chime once per utterance, forever (2026-07-15 hardware
    /// finding: "the Meta sound every ~5s"), and the same session cycling
    /// silently killed the assistant playback engine. Android's engine
    /// holds one continuous mic stream across recognizer restarts — this
    /// mirrors it.
    private func teardownRecognition() {
        session?.cancel()
        session = nil
    }

    /// Full teardown: recognition session + the mic subscription (which
    /// releases the shared audio session when we are the last consumer).
    /// Engine stop / toggle-off only — the privacy contract.
    private func teardownSession() {
        teardownRecognition()
        if let id = bufferSubscriptionId {
            audioInput.unsubscribe(id)
            bufferSubscriptionId = nil
        }
    }

    private func scheduleRestart() {
        guard !stopped, !restartScheduled else { return }
        restartScheduled = true
        let delayNs = UInt64(Self.restartDelayMs) * 1_000_000
        teardownRecognition()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self else { return }
            self.restartScheduled = false
            if !self.stopped {
                self.startSession()
            }
        }
    }

    /// Retry a failed audio-input subscribe. Slower cadence than the
    /// restart loop (`inputRetryDelayMs` vs `restartDelayMs`) — session
    /// activation races settle in wall-clock time, not render cycles.
    private func scheduleInputRetry() {
        guard !stopped, !restartScheduled else { return }
        restartScheduled = true
        let delayNs = UInt64(Self.inputRetryDelayMs) * 1_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self else { return }
            self.restartScheduled = false
            if !self.stopped {
                self.startSession()
            }
        }
    }

    /// Per-buffer endpoint check, on the main actor. Runs the
    /// speech→silence state machine and finishes the utterance after
    /// `silenceEndpointMs` of post-speech silence so Apple delivers the
    /// FINAL the wake matcher needs.
    private func endpointTick(rms: Double, nowMs: Int64) {
        guard session != nil else { return }
        if let requestedAt = finishRequestedAtMs {
            if nowMs - requestedAt > Self.finalBackstopMs {
                finishRequestedAtMs = nil
                scheduleRestart()
            }
            return
        }
        if rms >= Self.speechRmsThreshold {
            utteranceHadSpeech = true
            lastSpeechAtMs = nowMs
        } else if utteranceHadSpeech, nowMs - lastSpeechAtMs >= Self.silenceEndpointMs {
            utteranceHadSpeech = false
            finishRequestedAtMs = nowMs
            session?.finishAudio()
        }
    }

    /// Mean-square amplitude of the buffer's first channel, normalized to
    /// [0, 1]. Cheap enough for the render thread.
    private static nonisolated func rms(of buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let ch = buffer.floatChannelData {
            var sum = 0.0
            let p = ch[0]
            for i in 0..<frames {
                let s = Double(p[i])
                sum += s * s
            }
            return (sum / Double(frames)).squareRoot()
        }
        if let ch = buffer.int16ChannelData {
            var sum = 0.0
            let p = ch[0]
            for i in 0..<frames {
                let s = Double(p[i]) / 32768.0
                sum += s * s
            }
            return (sum / Double(frames)).squareRoot()
        }
        return 0
    }

    /// `no_match` / `speech_timeout` / similar "user paused" categories
    /// are recoverable: restart-on-silence is the locked behavior. Hard
    /// failures (recognizer unavailable, permission revoked) are surfaced
    /// to the caller.
    private static func isRecoverable(_ error: Error) -> Bool {
        if let stt = error as? SttError {
            switch stt {
            case .noMatch, .speechTimeout: return true
            // recognizerBusy is recoverable on Android (slower devices hit it
            // during the restart loop). On iOS SFSpeechRecognizer doesn't
            // raise it directly, but treat as recoverable for parity.
            case .recognizerBusy: return true
            case .permissionDenied, .recognizerUnavailable, .audioInputUnavailable, .networkError: return false
            }
        }
        // Bridge platform errors. NSError code constants from Speech.framework.
        let nsErr = error as NSError
        if nsErr.domain == "kAFAssistantErrorDomain" {
            // 203: no_match. 1101/1110/1700: timeouts / silent.
            if [203, 1101, 1110, 1700].contains(nsErr.code) {
                return true
            }
        }
        return false
    }
}

/// Stop handle returned by `PlatformSttEngine.start`. `close()` is
/// idempotent and runs on the main actor regardless of caller context.
struct SttEngineHandle: Sendable {
    private let closer: @Sendable () -> Void
    init(closer: @escaping @Sendable () -> Void) { self.closer = closer }
    func close() { closer() }
}

enum SttError: Error, Sendable {
    case permissionDenied
    case recognizerUnavailable
    case audioInputUnavailable
    case noMatch
    case speechTimeout
    case networkError
    case recognizerBusy
}

/// Map typed `SttError` to a `TransportError` for emission via
/// `TransportEvent.error`. Stable snake_case reason strings match
/// Android's mapping verbatim so `getEventLog` filtering works identically
/// across platforms. See PHASE_6_PLAN.md §8.4. Pulled out of
/// RealMetaTransport so it's reachable from macOS unit tests (RealMeta
/// is `#if os(iOS)` gated).
enum SttErrorMapper {
    static func map(_ error: Error) -> TransportError {
        if let stt = error as? SttError {
            switch stt {
            case .permissionDenied: return .hardwareUnavailable(reason: "stt_permission_denied")
            case .recognizerUnavailable: return .hardwareUnavailable(reason: "stt_engine_unavailable")
            case .audioInputUnavailable: return .hardwareUnavailable(reason: "stt_audio_input_unavailable")
            case .networkError: return .hardwareUnavailable(reason: "stt_network_error")
            case .recognizerBusy: return .hardwareUnavailable(reason: "stt_recognizer_busy")
            case .noMatch, .speechTimeout:
                // These are recoverable inside PlatformSttEngine; if they
                // ever reach onError it means the engine has already
                // exhausted its restart budget. Surface as engine-unavailable
                // so the agent sees a single stable cause.
                return .hardwareUnavailable(reason: "stt_engine_unavailable")
            }
        }
        // The core `platformError` factory accepts any `Error`, so the prior
        // `as? (any Error & Sendable)` narrowing is no longer needed.
        return .platformError(wrapping: error)
    }
}

/// Test seam. Production code uses `SystemSttSessionFactory` to wrap
/// SFSpeechRecognizer; tests inject a fake that emits canned events.
protocol SttSessionFactory: Sendable {
    @MainActor
    func makeSession(
        config: TranscriptionConfig,
        onPartial: @escaping (String, Float) -> Void,
        onFinal: @escaping (String, Int64, Int64, Float) -> Void,
        onError: @escaping (Error) -> Void
    ) -> (any SttSession)?
}

protocol SttSession: AnyObject {
    @MainActor func append(_ buffer: AVAudioPCMBuffer)
    @MainActor func cancel()
    /// Gracefully end the utterance: stop accepting audio and let the
    /// recognizer deliver its FINAL result (unlike `cancel()`, which
    /// discards it). Driven by the engine's silence endpointer.
    @MainActor func finishAudio()
}

/// A small `weak self` helper so the closure handed to `SttEngineHandle`
/// doesn't pin the engine alive.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { self.value = v }
}

#if canImport(Speech)

/// Production factory: wraps `SFSpeechRecognizer` /
/// `SFSpeechAudioBufferRecognitionRequest` / `SFSpeechRecognitionTask`.
/// `SttSession.append` forwards directly to
/// `SFSpeechAudioBufferRecognitionRequest.append`, which the framework
/// documents as thread-safe.
final class SystemSttSessionFactory: SttSessionFactory {
    init() {}

    @MainActor
    func makeSession(
        config: TranscriptionConfig,
        onPartial: @escaping (String, Float) -> Void,
        onFinal: @escaping (String, Int64, Int64, Float) -> Void,
        onError: @escaping (Error) -> Void
    ) -> (any SttSession)? {
        let locale = Locale(identifier: config.language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            onError(SttError.recognizerUnavailable)
            return nil
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = config.partial
        // Prefer ON-DEVICE recognition when the locale supports it
        // (supersedes §4.2's server-side default — decided 2026-07-15):
        // this engine backs the always-on wake listener, and an always-on
        // mic must not stream room audio to Apple's servers. On-device
        // also lifts the ~1-minute server task limit. Falls back to the
        // server path where on-device is unavailable.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    let segments = result.bestTranscription.segments
                    let avg: Float
                    if segments.isEmpty {
                        avg = 1.0
                    } else {
                        let sum = segments.reduce(Float(0)) { $0 + $1.confidence }
                        avg = sum / Float(segments.count)
                    }
                    if result.isFinal {
                        // SFSpeechRecognizer reports segment timestamps
                        // relative to the *current* recognition task, not
                        // wall-clock or stream-start. The continuous loop
                        // restarts the task after every final result (per
                        // §4.3), so startMs/endMs reset to ~0 on each
                        // restart. Consumers of `transport.transcript_emitted`
                        // that need monotonic-across-restarts timing must
                        // anchor against their own clock — see
                        // PHASE_6_PLAN.md §6.2.
                        let startSec = segments.first?.timestamp ?? 0
                        let totalDur = segments.reduce(0.0) { $0 + $1.duration }
                        let startMs = Int64(startSec * 1000)
                        let endMs = startMs + Int64(totalDur * 1000)
                        onFinal(text, startMs, endMs, avg)
                    } else {
                        onPartial(text, avg)
                    }
                } else if let error {
                    onError(error)
                }
            }
        }
        return SystemSttSession(request: request, task: task)
    }
}

private final class SystemSttSession: SttSession {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask

    init(request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask) {
        self.request = request
        self.task = task
    }

    @MainActor
    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    @MainActor
    func cancel() {
        request.endAudio()
        task.cancel()
    }

    @MainActor
    func finishAudio() {
        // End-of-utterance: no task.cancel() — the task runs on to deliver
        // `isFinal` and then completes on its own.
        request.endAudio()
    }
}

#endif // canImport(Speech)

#endif // canImport(AVFAudio)
