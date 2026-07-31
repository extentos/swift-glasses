import Foundation

#if os(iOS)

/// The **vendorless baseline transport**: a complete voice runtime over the
/// phone's own Bluetooth audio routing, with no vendor SDK, no vendor
/// credentials, and no device-pairing flow. Swift counterpart of Android's
/// `SystemAudioTransport`.
///
/// Smart glasses with a microphone and speaker present themselves to the phone
/// as an ordinary Bluetooth hands-free device. That is true of Ray-Ban Meta too
/// — their audio was never carried by MWDAT. So this transport is not a reduced
/// imitation of [`RealMetaTransport`]; it is the *same audio substrate*
/// ([`SystemAudioBridge`]) with the vendor half absent. What a vendor transport
/// adds on top is camera and display, not voice.
///
/// What works here, in full: `glasses.assistant.*` (turn-taking, barge-in, tool
/// calling, conversation memory, local and cloud models), `audio.transcriptions`,
/// `audio.audioChunks`, `audio.recordDiscrete`, `audio.speak` / `cancelSpeak` /
/// `earcon`, and streamed assistant PCM out.
///
/// Honestly absent: camera and display. Both refuse with a typed error naming
/// the upgrade path, and `isDisplayCapable()` reports false so capability-guarded
/// code degrades per the documented policy.
///
/// ## Connection semantics
///
/// The phone always has a microphone and a speaker, so this transport reports
/// connected whenever audio is available — it never strands a developer with a
/// dead SDK because glasses are in their case, and `recordDiscrete` (which the
/// core gates on connection) keeps working. Which device is actually live is a
/// routing question, not a connection question. See the Android class doc and
/// `shared-context/decisions-in-flight/system-audio-baseline-transport.md`.
public final class SystemAudioTransport: GlassesTransport, @unchecked Sendable {

    /// Not a vendor — the absence of one. Deliberately not a `GlassesVendor`
    /// case: that dial is the vendor-integration axis, and this transport is
    /// what you use when you have integrated no vendor at all.
    public static let systemAudioVendor = "system_audio"

    private let eventsContinuation: AsyncStream<TransportEvent>.Continuation
    public nonisolated let events: AsyncStream<TransportEvent>

    private let bridge: SystemAudioHardwareBridge
    private let core: RealMetaCore

    public init() {
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = stream
        self.eventsContinuation = continuation

        let bridge = SystemAudioHardwareBridge()
        self.bridge = bridge
        self.core = RealMetaCore(
            bridge: bridge,
            events: ShellEventObserver(continuation: continuation)
        )
        bridge.attachCore(core)
        // Route observing is independent of connect — eager, mirroring
        // RealMetaTransport's eager hardware observers.
        bridge.startHardwareObservers()
    }

    // MARK: - Lifecycle

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
        bridge.stopHardwareObservers()
        bridge.teardown()
        eventsContinuation.finish()
    }

    // MARK: - Camera (typed refusal — no vendor path here)

    public func capturePhoto(config: PhotoConfig) async -> ExtentosResult<Photo, CaptureError> {
        .failure(Self.noCameraRefusal(op: "capturePhoto"))
    }

    public func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError> {
        .failure(Self.noCameraRefusal(op: "captureVideo"))
    }

    public nonisolated func videoFrames(config: VideoFrameConfig) -> AsyncStream<VideoFrame> {
        // Unreachable in practice: DefaultCameraClient's no-camera gate reads
        // `videoStreamUnavailable()` and throws CameraUnavailable on the customer-facing
        // AsyncThrowingStream before this is ever iterated. Kept as the safe floor
        // for a caller holding the transport directly.
        AsyncStream { $0.finish() }
    }

    /// The stream's half of the refusal — the same error the discrete paths
    /// return, so all three camera entry points agree.
    public nonisolated func videoStreamUnavailable() -> CaptureError? {
        Self.noCameraRefusal(op: "video_frames")
    }

    private static func noCameraRefusal(op: String) -> CaptureError {
        .platformError(
            code: "system_audio_no_camera",
            message: "\(op) is not available on the system-audio transport: it reaches the "
                + "glasses through the phone's Bluetooth audio routing, which carries voice "
                + "only — no vendor SDK is connected, so there is no camera path. Voice "
                + "primitives (assistant, transcriptions, recordDiscrete, speak, audioChunks) "
                + "are fully functional. To add camera or display, adopt a vendor transport "
                + "and guard the call on glasses.capabilities.camera."
        )
    }

    public nonisolated func isCameraPaused() -> Bool { false }

    // MARK: - Display (absent — the capability gate is the contract)

    public nonisolated func isDisplayCapable() -> Bool { false }

    // showDisplay / clearDisplay inherit the protocol's no-op defaults: an
    // absent-capability call is always safe, never throws.

    // MARK: - Mic

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

    public nonisolated func audioChunks(config: AudioChunkConfig) -> AsyncStream<AudioChunk> {
        bridge.audio.audioChunksStream(config: config)
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

    // MARK: - Audio out

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

    public func earcon(_ sound: EarconSound, volume: Float) async {
        core.earcon(sound: sound, volume: volume)
    }

    public nonisolated func sendOutgoingAudioChunk(sampleRate: Int32, pcmBytes: Data) {
        bridge.audio.playOutgoingAudioChunk(sampleRate: sampleRate, pcmBytes: pcmBytes)
    }

    public nonisolated func cancelOutgoingAudio() {
        // The barge-in flush — drops audio already queued on the player node so
        // an interruption stops the assistant audibly NOW.
        bridge.audio.flushOutgoingAudio()
    }

    /// Bluetooth HFP is intrinsically narrowband while the mic is open, and that
    /// is the wire this transport plays over. Asking a realtime provider for
    /// hi-fi it cannot carry only wastes bandwidth and forces a resample.
    public nonisolated var outgoingAudioFidelity: OutgoingAudioFidelity { .narrowband }
}

#endif // os(iOS)
