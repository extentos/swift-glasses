import Foundation

#if os(iOS)
import MWDATCore

/// Phase 2b transport — a thin Swift shell over the Rust [`RealMetaCore`].
///
/// The protocol orchestration (connect walk: SDK init → registration →
/// create-session → start-session; `GlassesState` machine; capture
/// orchestration; transcription multiplexer; `HardwareAlert` routing) lives
/// in `extentos-core/src/real_meta/`. The Meta DAT SDK calls + every Apple
/// framework call (AVAudioSession, AVSpeechSynthesizer, SFSpeechRecognizer,
/// CallKit, UIApplication lifecycle, NotificationCenter observers) live in
/// [`MetaHardwareBridge`].
///
/// The shell here:
///  1. Constructs the bridge + core and wires their back-references.
///  2. Bridges the core's `TransportEventObserver` onto an
///     `AsyncStream<TransportEvent>` (the customer-facing `events` surface).
///  3. Maps the public Swift [`GlassesTransport`] surface onto the core's
///     flat per-arg method shapes.
///  4. Routes streaming primitives (`videoFrames`, `audioChunks`) through
///     the bridge directly (the core has no work for those — R10 design);
///     `transcriptions` through the core (multi-subscriber fan-out +
///     `TranscriptEmitted` events).
///  5. Keeps `handleUrl(_:)` shell-side (R3 — URL-callback is iOS-specific
///     and never crosses the FFI; the bridge's `start_registration` is the
///     core-facing trigger).
public final class RealMetaTransport: GlassesTransport, @unchecked Sendable {

    private let eventsContinuation: AsyncStream<TransportEvent>.Continuation
    public nonisolated let events: AsyncStream<TransportEvent>

    private let bridge: MetaHardwareBridge
    private let core: RealMetaCore

    public init() {
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = stream
        self.eventsContinuation = continuation

        let bridge = MetaHardwareBridge()
        self.bridge = bridge
        self.core = RealMetaCore(
            bridge: bridge,
            events: ShellEventObserver(continuation: continuation)
        )
        bridge.attachCore(core)
        // Hardware observers are independent of `connect()` — start eagerly
        // so thermal / route / call / lifecycle events stream from app
        // start. Mirrors Android.
        bridge.startHardwareObservers()
    }

    // MARK: - GlassesTransport lifecycle

    public func connect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError> {
        if let err = await core.connect(deviceId: deviceId) {
            return .failure(err)
        }
        return .success(())
    }

    public func disconnect() async {
        await core.disconnect()
    }

    public func shutdown() async {
        await core.shutdown()
        bridge.teardown()
        eventsContinuation.finish()
    }

    /// Full-band voice generation. The narrowband default assumed the BT
    /// HFP link is "intrinsically 8 kHz while the mic is open" — modern
    /// iPhone↔Ray-Ban pairs negotiate wideband speech (proven on-device
    /// 2026-07-15: the shared input node runs at 16 kHz), so 8 kHz µ-law
    /// generation pre-truncated the assistant's voice to half the
    /// bandwidth the link carries, plus µ-law quantization noise.
    /// Generate 24 kHz PCM and let the output mixer resample to whatever
    /// the link negotiated — ≥ narrowband quality on every link type
    /// (generation is the irreversible quality bottleneck).
    public nonisolated var outgoingAudioFidelity: OutgoingAudioFidelity { .hiFi }

    /// Forwards a URL callback from the host app's `onOpenURL` to the MWDAT
    /// companion registration handler. Returns `true` if MWDAT consumed the
    /// URL. **Stays on the shell** (R3) — registration triggers are
    /// platform-specific and never need to cross the FFI; the core only sees
    /// the resulting `RegistrationOutcome` via `bridge.start_registration`.
    public nonisolated func handleUrl(_ url: URL) async -> Bool {
        (try? await MWDATCore.Wearables.shared.handleUrl(url)) ?? false
    }

    // MARK: - Transport ops

    public func capturePhoto(config: PhotoConfig) async -> ExtentosResult<Photo, CaptureError> {
        switch await core.capturePhoto(resolution: config.resolution, format: config.format, dedicatedCapture: config.dedicatedCapture) {
        case .ok(let photo): return .success(photo)
        case .err(let err): return .failure(err)
        }
    }

    public func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError> {
        // F-R4-05 cancellation pattern, same shape as BrowserSimTransport.
        // The customer cancels at await-time; the in-flight core future
        // stays alive long enough for the abort frame to drive the bridge,
        // which finalises the partial via `on_video_captured`. The bounded
        // drain stops a hung bridge from pinning the customer's Task
        // forever.
        let work = Task<RealMetaCaptureVideoResult, Never> { [core] in
            await core.captureVideo(
                maxDurationSeconds: config.maxDurationSeconds.map(Int32.init),
                includeAudio: config.includeAudio,
                format: config.format,
                resolution: config.resolution,
                frameRate: Int32(config.frameRate)
            )
        }

        // Happy path: `await work.value` is non-cancellation-aware on
        // `Task<T, Never>`, so caller cancellation does not propagate into
        // the await. The onCancel hook fires `abortCaptureVideo` and the
        // body keeps waiting for `work` to resolve via the partial path.
        let bounded: RealMetaCaptureVideoResult? = await withTaskCancellationHandler {
            await Self.awaitWithBound(work, timeoutMs: nil)
        } onCancel: {
            Task { [core] in
                await core.abortCaptureVideo()
            }
        }

        if let bounded = bounded {
            switch bounded {
            case .ok(let clip): return .success(clip)
            case .err(let err): return .failure(err)
            }
        }
        // Bounded re-await after a hung happy path. The first call returns
        // `nil` only if `awaitWithBound` was invoked with a timeout — which
        // is `nil` above, so this branch is functionally a backstop. Kept
        // as a parity guard with the bounded-cancel pattern used by
        // BrowserSim's Stage-1 follow-up #2 fix.
        let drained = await Self.awaitWithBound(
            work,
            timeoutMs: UInt64(Self.videoDrainTimeoutMs + 1_000)
        )
        if let drained = drained {
            switch drained {
            case .ok(let clip): return .success(clip)
            case .err(let err): return .failure(err)
            }
        }
        return .failure(.platformError(wrapping: BrowserSimError.timeout))
    }

    public func recordAudio(config: AudioRecordConfig) async -> ExtentosResult<AudioRecording, AudioError> {
        switch await core.recordAudio(
            maxDurationSeconds: config.maxDurationSeconds.map(Int32.init),
            silenceTimeoutSeconds: Double(config.silenceTimeoutSeconds),
            quality: config.quality
        ) {
        case .ok(let recording): return .success(recording)
        case .err(let err): return .failure(err)
        }
    }

    public func speak(text: String, config: SpeakConfig) async -> ExtentosResult<Void, AudioError> {
        switch await core.speak(
            text: text,
            voice: config.voice,
            rate: Double(config.rate),
            pitch: Double(config.pitch),
            volume: Double(config.volume),
            waitForCompletion: config.waitForCompletion
        ) {
        case .ok: return .success(())
        case .err(let err): return .failure(err)
        }
    }

    public func cancelSpeak() async {
        core.cancelSpeak()
    }

    /// Barge-in flush: drop the assistant audio already queued on the
    /// playback engine. Without this override the protocol's no-op
    /// default swallowed the cancel and buffered faster-than-realtime
    /// audio kept playing seconds past the interrupt (2026-07-15
    /// hardware finding; Android has had the AudioTrack flush since F12).
    public nonisolated func cancelOutgoingAudio() {
        bridge.flushOutgoingAudio()
    }

    public func earcon(_ sound: EarconSound, volume: Float) async {
        core.earcon(sound: sound, volume: volume)
    }

    /// Phase 4 S0.M.1 — outgoing audio to the glasses speaker via
    /// AVAudioEngine + AVAudioPlayerNode with `.playAndRecord` /
    /// `.voiceChat` AVAudioSession. The bridge owns the engine lifecycle;
    /// we just forward each chunk. i16 LE PCM at `sampleRate`; mulaw
    /// providers (e.g. OpenAI Realtime `audio/pcmu`) decode in the
    /// provider before calling.
    ///
    /// Replaces the inherited `GlassesTransport` no-op default. Closes the
    /// Phase 3 silent-speak bug on real Ray-Bans independently of Phase 4
    /// timing — Phase 3's `SpeakAudioSink` shipping TTS chunks now reaches
    /// the glasses speaker. Mirrors Android RealMetaTransport.kt's
    /// `sendOutgoingAudioChunk` override.
    public func sendOutgoingAudioChunk(sampleRate: Int32, pcmBytes: Data) {
        bridge.playOutgoingAudioChunk(sampleRate: sampleRate, pcmBytes: pcmBytes)
    }

    // MARK: - Streams

    // The shared Rust core is the single source of truth for the temple-tap pause (it
    // tracks the stream state, fed by the bridge's `.paused` → onStreamStateChanged);
    // the shell's camera gate reads it. See GlassesTransport.isCameraPaused.
    public nonisolated func isCameraPaused() -> Bool { core.isCameraPaused() }

    public nonisolated func videoFrames(config: VideoFrameConfig) -> AsyncStream<VideoFrame> {
        bridge.videoFramesStream(config: config)
    }

    public nonisolated func audioChunks(config: AudioChunkConfig) -> AsyncStream<AudioChunk> {
        bridge.audioChunksStream(config: config)
    }

    public nonisolated func transcriptions(config: TranscriptionConfig) -> AsyncStream<Transcript> {
        AsyncStream { continuation in
            let sink = TranscriptAdapter { transcript in
                continuation.yield(transcript)
            }
            let streamId = self.core.startTranscriptionStream(
                language: config.language,
                partial: config.partial,
                sink: sink
            )
            continuation.onTermination = { [core = self.core] _ in
                core.stopTranscriptionStream(streamId: streamId)
            }
        }
    }

    // MARK: - Constants

    /// Mirrors the core's `VIDEO_DRAIN_TIMEOUT_MS`. iOS counterpart of
    /// Stage 2's Android `withTimeoutOrNull(VIDEO_DRAIN_TIMEOUT_MS +
    /// 1_000)` — a backstop in case a hung bridge never resolves the
    /// pending capture op.
    private static let videoDrainTimeoutMs: Int = 10_000

    // MARK: - Bounded await helper

    /// See `BrowserSimTransport.awaitWithBound` — same primitive,
    /// re-implemented here to avoid an inter-file private dependency. A
    /// future cleanup could hoist this into a `Concurrency.swift` helper.
    private static func awaitWithBound<T: Sendable>(
        _ work: Task<T, Never>,
        timeoutMs: UInt64?
    ) async -> T? {
        guard let timeoutMs = timeoutMs else {
            return await work.value
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let latch = OnceLatch()
            Task {
                let v = await work.value
                if latch.tryComplete() {
                    cont.resume(returning: v)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                if latch.tryComplete() {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Internal helpers

private final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryComplete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

#endif // os(iOS)
