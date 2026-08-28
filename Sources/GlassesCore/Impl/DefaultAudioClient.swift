import Foundation

// Post pure-SDK pivot: thin pass-through to the transport. No spec-driven
// stream lookup, no streamId variants, no outgoing-direction streams.
// Mirrors `android-library/.../impl/DefaultAudioClient.kt`, including the
// F-R5-18 / F-R5-13 transcription toggle gate (ported 2026-07-15 — iOS
// missed it, so STT ran regardless of the Voice Activation switch).

final class DefaultAudioClient: AudioClient, @unchecked Sendable {
    private let transport: any GlassesTransport
    private let toggles: (any ToggleClient)?
    private let onStreamLifecycle: (any StreamLifecycleHook)?

    private static let privacyModeToggle = "privacy_mode"
    private static let gateToggle = "audio_capture_enabled"
    private static let listeningModeToggle = "listening_mode"

    init(
        transport: any GlassesTransport,
        toggles: (any ToggleClient)? = nil,
        onStreamLifecycle: (any StreamLifecycleHook)? = nil
    ) {
        self.transport = transport
        self.toggles = toggles
        self.onStreamLifecycle = onStreamLifecycle
    }

    // MARK: - Raw outgoing audio (bring-your-own realtime model)
    // The outbound half of audioChunks. Same pipe the assistant providers
    // use; the only thing added here is the public door. Playback is NOT
    // gated by the mic toggles, those govern capture.

    func sendAudio(_ pcm16: Data, sampleRate: Int) async -> ExtentosResult<Void, AudioError> {
        // Empty chunk = nothing to send, per the core contract on
        // validateOutgoingAudio. Rejection rules and their messages are
        // core-owned (speak.rs) so Android cannot drift from this.
        if pcm16.isEmpty { return .success(()) }
        if let error = validateOutgoingAudio(sampleRate: Int32(sampleRate)) {
            return .failure(error)
        }
        transport.sendOutgoingAudioChunk(sampleRate: Int32(sampleRate), pcmBytes: pcm16)
        return .success(())
    }

    func stopAudio() async {
        transport.cancelOutgoingAudio()
    }

    var outputFidelity: OutgoingAudioFidelity {
        transport.outgoingAudioFidelity
    }

    // MARK: - Direct speak: local-voice routing (facts here, decisions in
    // the core's speak.rs — the resolveAudioGate/toggle_policy split; the
    // Kotlin mirror is DefaultAudioClient.kt). A voice id a registered
    // synthesizer claims and can serve streams through the outgoing-audio
    // path; everything else is the platform TTS engine, serve-until-ready.

    /// The in-flight direct-speak local synthesis, so `cancelSpeak` can
    /// abort it without ever touching an assistant-owned synthesis running
    /// on the same shared engine.
    private final class LocalSpeak: @unchecked Sendable {
        let synth: any LocalVoiceSynthesizer
        private let lock = NSLock()
        private var _cancelled = false
        private var _emitting = false

        init(synth: any LocalVoiceSynthesizer) { self.synth = synth }

        var cancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _cancelled
        }
        var emitting: Bool {
            lock.lock(); defer { lock.unlock() }
            return _emitting
        }
        func markCancelled() { lock.lock(); _cancelled = true; lock.unlock() }
        func markEmitting() { lock.lock(); _emitting = true; lock.unlock() }
    }

    private let speakLock = NSLock()
    private var activeLocalSpeak: LocalSpeak?

    func speak(_ text: String, config: SpeakConfig) async -> ExtentosResult<Void, AudioError> {
        let startMs = Int64(Date().timeIntervalSince1970 * 1000)
        let result = await runSpeak(text, config: config)
        var errorCode: String?
        if case .failure(let err) = result { errorCode = audioErrorCode(error: err) }
        await onStreamLifecycle?.onSpeak(
            outcome: errorCode == nil ? "completed" : "failed",
            durationMs: Int64(Date().timeIntervalSince1970 * 1000) - startMs,
            bargedIn: nil,
            // Length, never the utterance — the text is the user's content.
            charCount: text.count,
            errorCode: errorCode
        )
        return result
    }

    private func runSpeak(_ text: String, config: SpeakConfig) async -> ExtentosResult<Void, AudioError> {
        if let synth = await localSynthFor(config.voice) {
            if await speakViaLocalSynth(synth, text: text, config: config) {
                return .success(())
            }
            // Genuine synthesis failure → the system voice serves this call.
        }
        return await transport.speak(text: text, config: config)
    }

    /// Gather the registry facts for the voice id and let the core route.
    /// The first policy call uses best-case facts: ids the core routes to
    /// the system voice unconditionally (nil/""/"system") never touch the
    /// registry — no engine construction, no warm-up.
    private func localSynthFor(_ voiceId: String?) async -> (any LocalVoiceSynthesizer)? {
        if resolveSpeakRoute(voiceId: voiceId, synthResolved: true, synthReady: true) == .systemTts {
            return nil
        }
        guard let voiceId, let synth = LocalVoiceRegistry.resolve(voiceId) else { return nil }
        // Idempotent; returns fast when the model isn't on disk (system
        // voice serves — serve-until-ready). When it IS on disk, the first
        // natural-voice speak pays the one-time engine load here rather
        // than silently serving the system voice with no path to ready.
        await synth.warmUp()
        let ready = await synth.isReady()
        switch resolveSpeakRoute(voiceId: voiceId, synthResolved: true, synthReady: ready) {
        case .localSynth: return synth
        case .systemTts: return nil
        }
    }

    /// One utterance through the local synthesizer, streaming into the
    /// transport's outgoing-audio path (audible at the FIRST chunk — the
    /// assistant mouth's K3 semantics). Returns true when this call is done
    /// (played out or cancelled); false only on genuine synthesis failure,
    /// where the caller serves the system voice instead.
    ///
    /// `SpeakConfig.waitForCompletion` waits out the playback remainder
    /// (core-owned accounting, tail pad included); false returns once
    /// synthesis finishes, with the tail still playing. rate/pitch apply
    /// to the platform voice only — a local voice speaks at model prosody.
    private func speakViaLocalSynth(
        _ synth: any LocalVoiceSynthesizer,
        text: String,
        config: SpeakConfig
    ) async -> Bool {
        let call = LocalSpeak(synth: synth)
        speakLock.lock(); activeLocalSpeak = call; speakLock.unlock()
        defer {
            speakLock.lock()
            if activeLocalSpeak === call { activeLocalSpeak = nil }
            speakLock.unlock()
        }
        let gain = config.volume
        let t0 = Self.nowMs()
        let transport = self.transport
        let seconds = await synth.synthesize(text) { pcm, rate in
            call.markEmitting()
            // The cancel guard lives HERE, not only in the engine: on a
            // shared engine cancelSpeak() may not abort a synthesis it
            // can't prove is ours — dropping the chunks is the guarantee.
            guard !call.cancelled else { return }
            let bytes = gain >= 1.0 ? pcm : scalePcm16Gain(pcm: pcm, gain: gain)
            transport.sendOutgoingAudioChunk(sampleRate: rate, pcmBytes: bytes)
        }
        // Cancelled = done. NEVER fall back — the b24 trace: a barge-in
        // would re-speak the interrupted text in the system voice.
        if call.cancelled { return true }
        guard let seconds else { return false }
        if config.waitForCompletion {
            let remainMs = speakPlaybackRemainderMs(audioSeconds: seconds, elapsedMs: Self.nowMs() - t0)
            if remainMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainMs) * 1_000_000)
            }
        }
        return true
    }

    func cancelSpeak() async {
        speakLock.lock()
        let call = activeLocalSpeak
        speakLock.unlock()
        if let call {
            call.markCancelled()
            // Abort engine compute + drain downstream audio only when the
            // live synthesis is provably OURS (a chunk has been emitted).
            // On the shared engine, an assistant segment may hold the
            // synthesis serialization instead — its speech is not this
            // method's to kill, and flushing would clip it. The emit guard
            // above still silences OUR call the moment it runs.
            if call.emitting {
                await call.synth.cancel()
                transport.cancelOutgoingAudio()
            }
        }
        await transport.cancelSpeak()
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func earcon(_ sound: EarconSound, volume: Float) async {
        await transport.earcon(sound, volume: volume)
    }

    func recordDiscrete(config: AudioRecordConfig) async -> ExtentosResult<AudioRecording, AudioError> {
        let startMs = Int64(Date().timeIntervalSince1970 * 1000)
        let result = await transport.recordAudio(config: config)
        var errorCode: String?
        if case .failure(let err) = result { errorCode = audioErrorCode(error: err) }
        // A silence-bounded clip is a discrete capture, same as a photo.
        await onStreamLifecycle?.onCapture(
            kind: "audio_clip",
            outcome: errorCode == nil ? "success" : "failure",
            durationMs: Int64(Date().timeIntervalSince1970 * 1000) - startMs,
            errorCode: errorCode,
            source: nil,
            sizeBytes: nil
        )
        return result
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
