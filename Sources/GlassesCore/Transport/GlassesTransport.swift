import Foundation

// Internal transport abstraction. See docs/mcp/TRANSPORT.md for the canonical
// contract. Swift counterpart of the Kotlin `GlassesTransport` interface.
//
// The transport *data types* — `TransportEvent`, `TranscriptSource`,
// `TransportChosen`, `TransportSelectionSource` — migrated to extentos-core in
// Phase 2.0 (see MigratedCoreTypes.swift for the restored `wireValue`
// accessors). This interface stays a hand-written shell type: uniffi has no
// equivalent for `async` / `AsyncStream` signatures. The transport *logic*
// migrates in Phase 2a/2b.

public protocol GlassesTransport: Sendable {
    var events: AsyncStream<TransportEvent> { get }

    func connect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError>
    func disconnect() async

    func capturePhoto(config: PhotoConfig) async -> ExtentosResult<Photo, CaptureError>
    func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError>
    func recordAudio(config: AudioRecordConfig) async -> ExtentosResult<AudioRecording, AudioError>

    func videoFrames(config: VideoFrameConfig) -> AsyncStream<VideoFrame>
    func audioChunks(config: AudioChunkConfig) -> AsyncStream<AudioChunk>
    func transcriptions(config: TranscriptionConfig) -> AsyncStream<Transcript>

    /// Whether the camera stream is PAUSED by the wearer's temple tap (a hardware
    /// privacy gesture; no app-callable resume in DAT 0.8). The single source of
    /// truth `DefaultCameraClient` gates every stream-needing primitive on.
    /// `RealMetaTransport` reads DAT's StreamState via the shared Rust core;
    /// `BrowserSimTransport` reads the surrogate's capture-button state (the sim's
    /// mirror of the temple tap). Mirrors Kotlin GlassesTransport.isCameraPaused.
    func isCameraPaused() -> Bool

    /// A shell-side capture gate declined an operation BEFORE it reached the
    /// transport (today: the `isCameraPaused` gate → `CaptureError.streamPaused`).
    /// Gives the transport a chance to record the denial in the session trace —
    /// without it the simulator's event log shows nothing at all for a denied
    /// capture (the request never crosses the wire). `BrowserSimTransport` emits a
    /// `capture_denied` frame (severity `warn` → the errors chip in getEventLog);
    /// hardware transports inherit the no-op. Mirrors Kotlin notifyCaptureDenied.
    func notifyCaptureDenied(op: String, reason: String, message: String)

    func speak(text: String, config: SpeakConfig) async -> ExtentosResult<Void, AudioError>
    /// Cancel any in-flight TTS started via `speak(...)`. Idempotent;
    /// no-op when nothing is speaking. See `AudioClient.cancelSpeak()`
    /// for the customer-facing barge-in framing — this transport-side
    /// hook is the underlying primitive.
    func cancelSpeak() async
    func earcon(_ sound: EarconSound, volume: Float) async

    /// Phase 3 / Track 2 audio-OUT — push a chunk of TTS PCM bytes
    /// downstream (to the sim browser via the hub's binary relay, or to
    /// HFP output on real hardware in v1.1). The shell's
    /// `SpeakAudioSink` impl calls this for each chunk pumped off A4's
    /// `TtsStream`. v1 OpenAI TTS = 24 kHz mono i16 LE bytes; pass
    /// `sampleRate=24000` to match.
    ///
    /// Sync call (no `async`) — the Rust core's matching method writes
    /// one JSON frame + one binary frame to the underlying WS and
    /// returns; the shell's `SpeakAudioSink.onChunk` callback is also
    /// sync (uniffi callback interface).
    ///
    /// Default no-op via the protocol extension below: transports
    /// without an outgoing audio path (`LocalSimTransport`,
    /// `RealMetaTransport` pre-HFP-wiring) inherit it; only
    /// `BrowserSimTransport` overrides today. RealMeta will override
    /// once HFP-out wiring lands.
    func sendOutgoingAudioChunk(sampleRate: Int32, pcmBytes: Data)

    /// Playback fidelity for the assistant's outgoing voice (see
    /// `OutgoingAudioFidelity`) — backs the OpenAI Realtime provider's choice
    /// of session output audio format. Generation is the irreversible quality
    /// bottleneck, so we ask OpenAI for the best the playback path can carry.
    /// Default `.narrowband` (extension below) — safe for real BT HFP/SCO
    /// glasses (8 kHz cap while the mic is open). `BrowserSimTransport`
    /// overrides to `.hiFi`; WebAudio has no such limit.
    /// Cancel any buffered outgoing assistant audio (the barge-in flush).
    /// Default no-op: transports without an outgoing audio path silently
    /// ignore the cancel. Mirrors Kotlin GlassesTransport.cancelOutgoingAudio.
    func cancelOutgoingAudio()

    /// Render a display tree (whole-display replace). Default no-op — a
    /// display call on a transport without a display path does nothing,
    /// silently (the decided degradation policy).
    func showDisplay(
        root: DisplayNode,
        onSelect: @escaping @Sendable (String) -> Void,
        onBack: (@Sendable () -> Void)?
    ) async

    /// Clear the display. Default no-op.
    func clearDisplay() async

    /// Whether the CONNECTED device has a display. Default false — never
    /// claim a screen the device doesn't have.
    func isDisplayCapable() -> Bool

    var outgoingAudioFidelity: OutgoingAudioFidelity { get }

    func shutdown() async

    /// Optional URL-callback forwarder. Transports that don't participate in
    /// registration flows (LocalSim, Phase 1) default to `false`; RealMeta
    /// forwards to `Wearables.shared.handleUrl(_:)`.
    func handleUrl(_ url: URL) async -> Bool
}

public extension GlassesTransport {
    func handleUrl(_ url: URL) async -> Bool { false }

    /// Default: not paused. `RealMetaTransport` and `BrowserSimTransport` both
    /// report the real state from the shared Rust core; `LocalSim` inherits this.
    func isCameraPaused() -> Bool { false }

    /// Default no-op — on real glasses the typed error result IS the observable
    /// surface; only `BrowserSimTransport` records the denial in the sim trace.
    func notifyCaptureDenied(op: String, reason: String, message: String) {
        // default no-op
    }

    /// Default no-op for transports without an outgoing audio path.
    /// `BrowserSimTransport` overrides to delegate to the Rust core's
    /// matching method. See protocol-method doc for the wire shape.
    func sendOutgoingAudioChunk(sampleRate: Int32, pcmBytes: Data) {
        // default no-op
    }

    /// Default narrowband — the safe choice for real BT HFP/SCO glasses.
    func cancelOutgoingAudio() {
        // default no-op
    }

    func showDisplay(
        root: DisplayNode,
        onSelect: @escaping @Sendable (String) -> Void,
        onBack: (@Sendable () -> Void)?
    ) async {
        // default no-op (no display path)
    }

    func clearDisplay() async {
        // default no-op
    }

    func isDisplayCapable() -> Bool { false }

    var outgoingAudioFidelity: OutgoingAudioFidelity { .narrowband }
}

/// Fidelity tier of the assistant's outgoing voice a transport's playback path
/// can carry. Selects the OpenAI Realtime session's output audio format.
public enum OutgoingAudioFidelity: Sendable {
    /// Full-band 24 kHz mono linear PCM (`audio/pcm`). The browser simulator
    /// plays through WebAudio, which has no Bluetooth narrowband limit.
    case hiFi
    /// 8 kHz mono G.711 µ-law (`audio/pcmu`) — telephony grade. Real Ray-Ban
    /// glasses play over BT HFP/SCO, intrinsically 8 kHz while the mic is open;
    /// matching the wire format avoids resampling.
    case narrowband
}
