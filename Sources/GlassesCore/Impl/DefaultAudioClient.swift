import Foundation

// Post pure-SDK pivot: thin pass-through to the transport. No spec-driven
// stream lookup, no streamId variants, no outgoing-direction streams.
// Mirrors `android-library/.../impl/DefaultAudioClient.kt`, including the
// F-R5-18 / F-R5-13 transcription toggle gate (ported 2026-07-15 — iOS
// missed it, so STT ran regardless of the Voice Activation switch).

final class DefaultAudioClient: AudioClient, @unchecked Sendable {
    private let transport: any GlassesTransport
    private let toggles: (any ToggleClient)?
    private let sounds: SoundRegistry
    private let onStreamLifecycle: (any StreamLifecycleHook)?

    private static let privacyModeToggle = "privacy_mode"
    private static let gateToggle = "audio_capture_enabled"
    private static let listeningModeToggle = "listening_mode"

    init(
        transport: any GlassesTransport,
        toggles: (any ToggleClient)? = nil,
        sounds: SoundRegistry = SoundRegistry(),
        onStreamLifecycle: (any StreamLifecycleHook)? = nil
    ) {
        self.transport = transport
        self.toggles = toggles
        self.sounds = sounds
        self.onStreamLifecycle = onStreamLifecycle
    }

    // MARK: - Named sounds (registry in the Rust core; playback = the
    // existing outgoing-audio path, so real glasses get the HFP-routed,
    // self-resurrecting pipe)

    func playSound(_ name: String, volume: Float) async -> ExtentosResult<Void, AudioError> {
        guard let sound = sounds.resolve(name: name, volume: volume) else {
            return .failure(.platformError(
                code: "sound_not_found",
                message: "No sound named \"\(name)\" — register it in code via registerSound or upload it in the dashboard Agent section."
            ))
        }
        transport.sendOutgoingAudioChunk(sampleRate: sound.sampleRate, pcmBytes: sound.pcm)
        return .success(())
    }

    func registerSound(_ name: String, pcm16: Data, sampleRate: Int) {
        sounds.register(name: name, sampleRate: Int32(sampleRate), pcm: pcm16)
    }

    func soundNames() -> [String] {
        sounds.names()
    }

    func speak(_ text: String, config: SpeakConfig) async -> ExtentosResult<Void, AudioError> {
        await transport.speak(text: text, config: config)
    }

    func cancelSpeak() async {
        await transport.cancelSpeak()
    }

    func earcon(_ sound: EarconSound, volume: Float) async {
        await transport.earcon(sound, volume: volume)
    }

    func recordDiscrete(config: AudioRecordConfig) async -> ExtentosResult<AudioRecording, AudioError> {
        await transport.recordAudio(config: config)
    }

    func audioChunks(config: AudioChunkConfig) -> AsyncStream<AudioChunk> {
        wrapAudio(transport.audioChunks(config: config), config: config)
    }

    func transcriptions(config: TranscriptionConfig) -> AsyncStream<Transcript> {
        wrapTranscription(gatedTranscriptions(config: config), config: config)
    }

    // F-R5-18 / F-R5-13 parity with Android: STT is gated by privacy_mode,
    // audio_capture_enabled, AND listening_mode. The connection-page Voice
    // Activation switch writes listening_mode — "off" is the canonical
    // user-facing STT kill-switch; unset defaults to listening-on so apps
    // written before the hard gate keep working. The gate is REACTIVE
    // (Android's `flatMapLatest`): flipping a toggle mid-stream cancels /
    // restarts the underlying transport session — mic and recognizer are
    // fully released while the gate is closed (battery + privacy) — while
    // the customer's AsyncStream stays open. Value grammar + composition
    // are core-owned (`toggle_policy.rs`, `transcriptionGateOpen`).
    private func gatedTranscriptions(config: TranscriptionConfig) -> AsyncStream<Transcript> {
        guard let toggles else { return transport.transcriptions(config: config) }
        let transport = self.transport
        return AsyncStream { continuation in
            let outer = Task {
                var inner: Task<Void, Never>?
                var lastOpen: Bool?
                for await state in toggles.state.stream {
                    if Task.isCancelled { break }
                    let open = transcriptionGateOpen(
                        privacyRaw: state.values[Self.privacyModeToggle]?.rawJsonString,
                        audioEnabledRaw: state.values[Self.gateToggle]?.rawJsonString,
                        listeningModeRaw: state.values[Self.listeningModeToggle]?.rawJsonString
                    )
                    if open == lastOpen { continue } // distinctUntilChanged
                    lastOpen = open
                    inner?.cancel()
                    inner = nil
                    if open {
                        inner = Task {
                            for await transcript in transport.transcriptions(config: config) {
                                if Task.isCancelled { break }
                                continuation.yield(transcript)
                            }
                        }
                    }
                }
                inner?.cancel()
            }
            continuation.onTermination = { _ in outer.cancel() }
        }
    }

    private func wrapAudio(_ stream: AsyncStream<AudioChunk>, config: AudioChunkConfig) -> AsyncStream<AudioChunk> {
        guard let hook = onStreamLifecycle else { return stream }
        let props: [String: JSONValue] = [
            "chunkMillis": .int(Int64(config.chunkMillis)),
            "sampleRate": .int(Int64(config.sampleRate)),
        ]
        return StreamLifecycleWrap.wrap(stream, streamType: "audio_chunks", props: props, hook: hook)
    }

    private func wrapTranscription(_ stream: AsyncStream<Transcript>, config: TranscriptionConfig) -> AsyncStream<Transcript> {
        guard let hook = onStreamLifecycle else { return stream }
        let props: [String: JSONValue] = [
            "language": .string(config.language),
            "partialResultsEnabled": .bool(config.partial),
        ]
        return StreamLifecycleWrap.wrap(stream, streamType: "transcription_incremental", props: props, hook: hook)
    }
}

extension JSONValue {
    /// Raw JSON text of a toggle value — the grammar `toggle_policy.rs`
    /// parses (Android passes `JSONValue.toString()`; this is the Swift
    /// equivalent). Scalars are hand-rendered so a bare string arrives
    /// quoted (`"off"` → `"\"off\""`) exactly like the Kotlin side.
    /// Internal: shared by the audio + camera toggle gates.
    var rawJsonString: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v):
            let escaped = v
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self),
                  let s = String(data: data, encoding: .utf8)
            else { return "null" }
            return s
        }
    }
}
