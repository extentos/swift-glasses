import Foundation

public protocol AudioClient: Sendable {
    func speak(_ text: String, config: SpeakConfig) async -> ExtentosResult<Void, AudioError>
    /// Cancel any in-flight TTS started via [speak]. Stops the platform
    /// TTS engine immediately (iOS `AVSpeechSynthesizer.stopSpeaking(at:
    /// .immediate)`; on Android `TextToSpeech.stop()`) and clears any
    /// queued audio on the speaker side.
    ///
    /// Idempotent — safe to call when nothing is speaking. Returns
    /// immediately; does not await an "actually stopped" confirmation
    /// (the platform TTS APIs themselves are fire-and-forget on stop).
    ///
    /// Canonical use: barge-in. Customer subscribes to
    /// [transcriptions] while an AI response is being spoken; when the
    /// user starts talking, they call `cancelSpeak()` from a different
    /// Task to interrupt the in-flight speech and listen to the user
    /// instead.
    func cancelSpeak() async
    func earcon(_ sound: EarconSound, volume: Float) async
    /// Play a named sound through the glasses speaker. Names come from
    /// dashboard-uploaded sounds (registered automatically at assistant
    /// start) or code registrations via [registerSound] — code wins on
    /// name collisions. There is no built-in vocabulary: the wake chime is
    /// the only Extentos-shipped sound and has its own channel. Unknown
    /// name → `.platformError(code: "sound_not_found")`. Plays through the
    /// same outgoing-audio path as the assistant voice (HFP-routed on real
    /// glasses; mixes if the assistant is mid-response).
    func playSound(_ name: String, volume: Float) async -> ExtentosResult<Void, AudioError>
    /// Register (or replace) a named sound: mono PCM16-LE bytes at
    /// `sampleRate` Hz. Registrations are process-lifetime.
    func registerSound(_ name: String, pcm16: Data, sampleRate: Int)
    /// Registered sound names, sorted.
    func soundNames() -> [String]
    func recordDiscrete(config: AudioRecordConfig) async -> ExtentosResult<AudioRecording, AudioError>
    func audioChunks(config: AudioChunkConfig) -> AsyncStream<AudioChunk>
    func transcriptions(config: TranscriptionConfig) -> AsyncStream<Transcript>
}

public extension AudioClient {
    func speak(_ text: String) async -> ExtentosResult<Void, AudioError> {
        await speak(text, config: SpeakConfig())
    }
    func earcon(_ sound: EarconSound) async {
        await earcon(sound, volume: 0.8)
    }
    func recordDiscrete() async -> ExtentosResult<AudioRecording, AudioError> {
        await recordDiscrete(config: AudioRecordConfig())
    }
    func audioChunks() -> AsyncStream<AudioChunk> {
        audioChunks(config: AudioChunkConfig())
    }
    func transcriptions() -> AsyncStream<Transcript> {
        transcriptions(config: TranscriptionConfig())
    }
    func playSound(_ name: String) async -> ExtentosResult<Void, AudioError> {
        await playSound(name, volume: 1.0)
    }
}

public struct SpeakConfig: Sendable {
    public var voice: String?
    public var rate: Float
    public var pitch: Float
    public var volume: Float
    public var waitForCompletion: Bool
    public init(
        voice: String? = nil,
        rate: Float = 1.0,
        pitch: Float = 0.0,
        volume: Float = 1.0,
        waitForCompletion: Bool = true
    ) {
        self.voice = voice
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.waitForCompletion = waitForCompletion
    }
}

public struct AudioRecordConfig: Sendable {
    /// Hard cap on the capture length, in whole seconds. `nil` (the
    /// default) means no time cap — the capture ends only on silence
    /// detection or cancellation. A non-nil value caps the capture at
    /// that many seconds regardless of silence. Mirrors Android's
    /// `AudioRecordConfig.maxDurationSeconds: Int?` after F-DF-02.
    public var maxDurationSeconds: Int?
    /// Unchanged by F-DF-02 — conversation-flow territory owned by a
    /// separate effort. The Int-vs-Android-Double asymmetry is
    /// deliberately out of scope; see
    /// shared-context/ios-audiorecordconfig-maxduration-findings.md.
    public var silenceTimeoutSeconds: Int
    public var quality: AudioQuality
    public init(
        maxDurationSeconds: Int? = nil,
        silenceTimeoutSeconds: Int = 2,
        quality: AudioQuality = .standard
    ) {
        self.maxDurationSeconds = maxDurationSeconds
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.quality = quality
    }
}

public struct AudioChunkConfig: Sendable {
    public var chunkMillis: Int
    public var sampleRate: Int
    public var backpressure: Backpressure
    public init(
        chunkMillis: Int = 20,
        sampleRate: Int = 16000,
        backpressure: Backpressure = .suspend(bufferSize: 16)
    ) {
        self.chunkMillis = chunkMillis
        self.sampleRate = sampleRate
        self.backpressure = backpressure
    }
}

public struct TranscriptionConfig: Sendable {
    public var language: String
    public var minPartialConfidence: Float
    public var partial: Bool
    public init(
        language: String = "en-US",
        minPartialConfidence: Float = 0.3,
        partial: Bool = true
    ) {
        self.language = language
        self.minPartialConfidence = minPartialConfidence
        self.partial = partial
    }
}

// `AudioRecording` → migrated to extentos-core in Phase 2.0. iOS delta on the
// core type: `rawAudioUrl: URL?` → `rawAudioUri: String?`. `AudioChunk` below
// stays native permanently — a hot-path binary carrier (decision 4).

public struct AudioChunk: Sendable {
    public let samples: Data
    public let sampleRate: Int
    public let timestampMs: Int64
    public init(samples: Data, sampleRate: Int, timestampMs: Int64) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestampMs = timestampMs
    }
}

// `Transcript` → migrated to extentos-core in Phase 2.0. iOS deltas on the
// core type: `confidence` is `Double` (was `Float`), and `Transcript.final`'s
// `startMs` / `endMs` are `Int64?` (optional, reordered after `confidence`).
// `EarconSound` / `AudioQuality` migrated in Phase 0/1.
