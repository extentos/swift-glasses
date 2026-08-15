// Local realtime v2 — the iOS shell around the Rust `ConversationLoop`
// (docs/design/free-tier/13 §B/§C, 14 Phase 2.5). This provider holds ZERO
// turn logic: it feeds events to the pure machine and executes the effects
// it returns. Ears (baseline: the SDK's own transcription stream), mouth
// (the SDK speak path), timers, and the brain — which is INJECTED through
// `LocalTierRegistry` so GlassesCore never depends on the MLX-heavy
// GlassesLocal product.
//
// Provider parity contract (doc 14 scope): the event stream is
// indistinguishable from the cloud provider's — the agent test loop and the
// host app cannot tell which brain answered.

import Foundation

// ── The public brain seam (implemented by GlassesLocal) ──────────────────

/// One customer tool, flattened for the brain boundary (schema as JSON
/// text so the seam carries no GlassesCore-internal types).
public struct LocalBrainTool: Sendable {
    public let name: String
    public let description: String
    public let schemaJson: String?
    public init(name: String, description: String, schemaJson: String?) {
        self.name = name
        self.description = description
        self.schemaJson = schemaJson
    }
}

/// One generate pass's numbers, surfaced for the session trace (prompt
/// tokens shrink to suffix-only once the brain's prompt cache is warm).
public struct LocalBrainStats: Sendable {
    public let promptTokens: Int
    public let generationTokens: Int
    public let promptSeconds: Double
    public let generateSeconds: Double
    /// Prompt tokens served from the brain's cross-turn cache.
    public let cacheReusedTokens: Int
    /// "warm" / "trim(-N)" / "cold(<reset reason>)" / "reprime" — a cold
    /// prefill in a trace always names the reset that caused it.
    public let cacheDisposition: String
    public init(
        promptTokens: Int, generationTokens: Int,
        promptSeconds: Double, generateSeconds: Double,
        cacheReusedTokens: Int = 0, cacheDisposition: String = ""
    ) {
        self.promptTokens = promptTokens
        self.generationTokens = generationTokens
        self.promptSeconds = promptSeconds
        self.generateSeconds = generateSeconds
        self.cacheReusedTokens = cacheReusedTokens
        self.cacheDisposition = cacheDisposition
    }
}

/// The local tier's brain contract. Cancellation is Task cancellation of
/// the in-flight `runTurn`/`composeGreeting` — implementations must be
/// abort-safe (history hygiene on every exit path).
/// A brain error that can explain itself to the USER in one spoken
/// sentence (what went wrong + what to do). The provider speaks this
/// instead of the generic apology — without it, a per-turn failure like
/// insufficientMemory repeats "I ran into a problem" forever with zero
/// actionable content (hardware finding, 2026-07-25).
public protocol SpeakableBrainError: Error {
    var spokenMessage: String { get }
}

public protocol LocalTurnBrain: Sendable {
    func warmUp() async throws
    /// Pre-compute the session prefix (system + tools) into the brain's
    /// prompt cache so the FIRST turn prefills suffix-only like every other
    /// turn (b7 trace: 20-token first-turn prefill with a warm prefix vs
    /// 3.1 s cold). Runs detached at provider start (app-session start,
    /// long before the wake) — never on the wake path.
    func prefillPrefix(instructions: String, tools: [LocalBrainTool]) async
    /// Drive one full user turn (tool loop inside). `onReplyChunk` streams
    /// sentence-boundary segments DURING generation; the returned reply is
    /// always the full text (history/telemetry). nil = silence.
    func runTurn(
        instructions: String,
        userText: String,
        tools: [LocalBrainTool],
        execute: @escaping @Sendable (_ name: String, _ argsJson: String) async -> String,
        onToolCalled: @escaping @Sendable (_ name: String, _ argsJson: String) -> Void,
        onToolResult: @escaping @Sendable (_ name: String, _ output: String) -> Void,
        onReplyChunk: @escaping @Sendable (_ text: String) -> Void,
        onStats: @escaping @Sendable (LocalBrainStats) -> Void
    ) async throws -> String?
    /// Model-composed greeting (the `Greeting.Custom` contract). Carries
    /// the session tools ONLY for prompt-cache prefix consistency: a
    /// tool-less greet diverges the cached prefix at the tools block, so
    /// turn 1 would re-prefill nearly everything the start-time warm paid
    /// for. (Not a tool-calling measure — that theory was disproven, doc 16
    /// round 2.)
    func composeGreeting(instructions: String, prompt: String?, tools: [LocalBrainTool]) async throws -> String?
    func clearHistory() async
}

/// GlassesLocal registers its brain factory here (one `ExtentosLocalTier
/// .register()` call in the app bootstrap). GlassesCore stays MLX-free.
///
/// SACRED-CHOICE AMENDMENT (`local-auto`, 2026-07-25). The rule that the SDK
/// never substitutes a model forbids SILENT substitution — not delegation.
/// Every CONCRETE id is still served exactly or refused honestly, unchanged.
/// `local-auto` is the single id whose meaning IS "resolve for me": the
/// developer deliberately delegated the choice, and the resolution is always
/// reported through `AssistantEvent.autoModelResolved`. Nothing about it is
/// silent, which is the property the rule exists to protect. Do not read Auto
/// as a violation.
public enum LocalTierRegistry {
    nonisolated(unsafe) public static var brainFactory: (@Sendable (_ modelId: String) -> (any LocalTurnBrain)?)?

    /// Resolves `local-auto` against THIS device. Registered by GlassesLocal,
    /// which owns the ladder and can read process memory; GlassesCore holds
    /// only the seam.
    ///
    /// `servedRemotely` is true for browser-sim sessions, where the gateway
    /// serves every rung server-side — so weights count as present for all of
    /// them and the choice turns purely on device class.
    ///
    /// Unregistered, `local-auto` resolves to the cloud fallback: with no
    /// engine module there is no local brain to choose, so "the best available
    /// brain" genuinely IS the cloud. Reported, never silent.
    nonisolated(unsafe) public static var autoResolver: (@Sendable (_ servedRemotely: Bool) -> AutoResolution)?
}

// ── The provider ─────────────────────────────────────────────────────────

internal final class LocalRealtimeProvider: AssistantProviderRuntime, @unchecked Sendable {

    private let config: AssistantConfig
    private let model: String
    /// Dashboard/config voice id ("system" default). A non-system local
    /// voice resolves through LocalVoiceRegistry (doc 19); unregistered or
    /// not-ready serves the system voice — serve-until-ready.
    private let voiceId: String
    private let voiceSynth: (any LocalVoiceSynthesizer)?
    private let brain: any LocalTurnBrain
    private let audio: any AudioClient
    private let transport: any GlassesTransport
    private let onAssistantEvent: @Sendable (AssistantEvent) -> Void

    /// The pure machine (Rust). All turn-taking truth lives in there.
    private let loop = ConversationLoop()
    /// Serializes handle()+effect-dispatch so effect ORDER matches the
    /// machine's intent even when events arrive from several tasks.
    private let machineLock = NSLock()

    private let stateLock = NSLock()
    private var started = false
    private var connected = false
    private var earsTask: Task<Void, Never>?
    /// Sim-substrate onset frames (speech_onset from the browser's VAD).
    private var onsetFrameTask: Task<Void, Never>?
    private var inferenceTask: Task<Void, Never>?
    /// Generation gate: chunk/terminal callbacks from a superseded brain
    /// task must never reach the machine (its own straggler protection
    /// can't tell generations apart once a NEW inference is in flight).
    private var inferenceGen: UInt64 = 0
    private var timers: [ConversationTimer: Task<Void, Never>] = [:]
    /// Durations of currently-armed timers — lets continued speech evidence
    /// re-arm the false-interruption window at its machine-chosen length
    /// (the machine owns policy; the shell owns the clock).
    private var history: [Turn] = []
    private var currentInstructions: String
    /// Onset time of the current user speech burst (for the classifier).
    private var speechBurstStartMs: Int64 = 0
    /// One machine SpeechStarted per RMS speech run (EarsTuning.onsetBargeIn
    /// path) — re-armed when the run ends.
    private var onsetRunFired = false

    // ── Mouth (single-owner serial queue; consecutive Speak effects are
    //    one logical utterance, one SpeechCompleted per segment) ──────────
    private var speechQueue: [String] = []
    private var currentSegment = ""
    private var speakPump: Task<Void, Never>?
    /// Set under stateLock at spawn — the Task var alone races its own
    /// completion (a drained pump could self-clear before the spawn-site
    /// assignment lands, wedging the mouth as "running" forever).
    private var pumpRunning = false
    private var lastSpokenText = ""
    private var speakingStartMs: Int64 = 0
    /// True once a warm pass (weights + prefix prefill) has completed. A
    /// wake that beats the warm gets the canned greeting INSTANTLY —
    /// composing on a cold brain is guaranteed slow (10.3s measured on
    /// iPhone 12, 2026-07-25), and the wake ack must not wait for it.
    private var brainWarmed = false

    // Per-turn trace marks.
    private let trace = LocalTierDiagnostics.shared
    private var turnStartMs: Int64 = 0
    private var firstChunkLogged = false
    private var firstAudioLogged = false

    private let classifier = InterruptionClassifier(config: InterruptionConfig(
        minDurationMs: 500,
        minWords: 0,
        backchannelWindowMs: 1000,
        backchannelOverrideDurationMs: 1500
    ))

    /// Silence auto-sleep: the machine's RequestSleep effect lands here —
    /// wired by DefaultAssistantClient to session.sleep(), identical to the
    /// cloud provider's onSilenceTimeout contract.
    private let onSilenceTimeout: @Sendable () -> Void

    init(
        config: AssistantConfig,
        model: String,
        voice: String? = nil,
        brain: any LocalTurnBrain,
        audio: any AudioClient,
        transport: any GlassesTransport,
        onAssistantEvent: @escaping @Sendable (AssistantEvent) -> Void,
        onSilenceTimeout: @escaping @Sendable () -> Void = {}
    ) {
        self.onSilenceTimeout = onSilenceTimeout
        self.config = config
        self.model = model
        let voiceId = voice ?? "system"
        self.voiceId = voiceId
        // Memoized resolve: the direct-speak path (DefaultAudioClient) and
        // this mouth share one loaded engine per voice id, not two model
        // copies in RAM.
        self.voiceSynth = voiceId == "system"
            ? nil : LocalVoiceRegistry.resolve(voiceId)
        self.brain = brain
        self.audio = audio
        self.transport = transport
        self.onAssistantEvent = onAssistantEvent
        self.currentInstructions = config.instructions
        // Honor AssistantConfig.silenceTimeout (nil = no auto-sleep) — the
        // same contract the cloud provider implements; the machine owns the
        // clock policy (arm/re-arm/cancel around LISTENING).
        loop.setSilenceTimeoutMs(ms: config.silenceTimeout.map { UInt32($0 * 1000) })
    }

    // ── Lifecycle ────────────────────────────────────────────────────────

    func start() async throws {
        stateLock.lock()
        if started { stateLock.unlock(); return }
        started = true
        stateLock.unlock()

        // Ears: the SDK's own transcription stream (baseline segmenter —
        // finals are utterances; the streaming-segmenter upgrade lands in
        // the bake-off without touching this provider's shape).
        let stream = audio.transcriptions()
        earsTask = Task { [weak self] in
            for await transcript in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                self.onTranscript(transcript)
            }
        }
        trace.beginSession(label: "session start — model \(model)")
        trace.record("tools: [\(config.tools.map(\.name).joined(separator: ", "))]")
        WakeLedger.shared.note("session: local provider start (\(model))")
        // RMS-onset barge-in (flag-gated, default dark): the ears post raw
        // speech-run durations; the classifier — word count unknown at
        // onset time — rules, ~0.5s after voice starts instead of the
        // measured ~0.8s+ first-partial wait. Everything downstream is the
        // machine's existing confirm-or-resume.
        if EarsTuning.onsetBargeIn {
            EarsActivityHub.shared.setListener { [weak self] runMs in
                self?.onSpeechRun(runMs)
            }
        }
        // Sim substrate for the SAME onset signal: the browser page's VAD
        // sends a `speech_onset` frame on each speech-run rising edge (the
        // batch STT there produces no partials, so without this a sim
        // barge-in waits out full transcription — "not crisp", 2026-07-24).
        // Feed it as a ~600ms run (clears the classifier's 500ms floor),
        // then reset the once-per-run latch. Hardware path untouched.
        if let sim = transport as? BrowserSimTransport {
            onsetFrameTask = Task { [weak self] in
                for await frame in sim.incomingTextFrames {
                    if Task.isCancelled { return }
                    guard case .object(let o) = frame,
                          case .string(let kind) = o["type"] ?? .null
                    else { continue }
                    switch kind {
                    case "speech_onset":
                        self?.onSpeechRun(600)
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        self?.onSpeechRun(0)
                    default:
                        break
                    }
                }
            }
        }
        // Weights + session-prefix warm at APP-session start — the wake is
        // typically much later, so the first turn (and the greeting) prefill
        // suffix-only. b7 ran this at connect() (the wake) and made the
        // greeting SLOWER; placement is the whole point.
        let instructions = composedInstructions()
        let tools = brainTools()
        Task { [weak self, brain] in
            try? await brain.warmUp()
            await brain.prefillPrefix(instructions: instructions, tools: tools)
            if let self {
                self.stateLock.lock()
                self.brainWarmed = true
                self.stateLock.unlock()
            }
        }
        // The voice engine (if any) warms in parallel with the brain — a
        // not-yet-ready synth just serves the system voice per segment.
        if let voiceSynth {
            Task { await voiceSynth.warmUp() }
        }
        // NO sessionStarted here: the local harness starts at app launch
        // (to keep the wake path warm) but the CONVERSATION hasn't begun.
        // Emitting at start() made every listener with cloud semantics —
        // the sim page's purple cue, its transcript policy — treat a
        // dormant harness as a live conversation (2026-07-24 sim test).
        // sessionStarted now rides connect(), the actual wake, matching
        // the cloud provider's meaning; wentDormant on sleep is emitted
        // provider-agnostically by DefaultAssistantClient.
    }

    func connect() async throws {
        stateLock.lock()
        let already = connected
        connected = true
        stateLock.unlock()
        if already { return }
        feed(.start)
        // Each dormant→awake transition is a (re)started conversation.
        onAssistantEvent(.sessionStarted(provider: "local", model: model, voice: voiceId))
        // Warm-up belt-and-braces: start() already warmed; this is a no-op
        // when it succeeded and a detached retry when it didn't (e.g. the
        // model download finished between app start and the wake).
        let instructions = composedInstructions()
        let tools = brainTools()
        Task { [weak self, brain] in
            try? await brain.warmUp()
            await brain.prefillPrefix(instructions: instructions, tools: tools)
            if let self {
                self.stateLock.lock()
                self.brainWarmed = true
                self.stateLock.unlock()
            }
        }
    }

    func disconnect() async {
        stateLock.lock()
        connected = false
        stateLock.unlock()
        feed(.stop)
    }

    func stop() async {
        stateLock.lock()
        let wasStarted = started
        started = false
        connected = false
        stateLock.unlock()
        guard wasStarted else { return }
        EarsActivityHub.shared.setListener(nil)
        feed(.stop)
        earsTask?.cancel()
        onsetFrameTask?.cancel()
        inferenceTask?.cancel()
        speakPump?.cancel()
        stateLock.lock()
        speechQueue.removeAll()
        currentSegment = ""
        pumpRunning = false
        for (_, t) in timers { t.cancel() }
        timers.removeAll()
        stateLock.unlock()
        onAssistantEvent(.sessionEnded(reason: .user, message: nil))
    }

    // ── Ears → events ────────────────────────────────────────────────────

    /// The onset path (EarsTuning.onsetBargeIn). Fires at most one machine
    /// SpeechStarted per speech run. Cancel is final (RDQ #73): a run that
    /// produces no real transcript leaves the machine simply listening.
    private func onSpeechRun(_ runMs: UInt32) {
        guard isConnected() else { return }
        stateLock.lock()
        if runMs == 0 {
            onsetRunFired = false
            stateLock.unlock()
            return
        }
        let already = onsetRunFired
        let speakingElapsed: UInt32? = speakingStartMs > 0
            ? UInt32(clamping: Self.nowMs() - speakingStartMs) : nil
        stateLock.unlock()
        if already { return }
        // SPEAKING-only by design: with cancel-is-final a false onset kills
        // the reply outright, so the gate matters — during THINKING the
        // transcript gate holds, and in SPEAKING the tape evidence carries
        // it (calibration 2026-07-23: 0 false onsets in 56 fired runs
        // across b17/b19/b21). If hardware ever shows false onsets, the
        // fix is tightening the classifier, not resurrecting resume.
        guard speakingElapsed != nil else { return }
        let obs = SpeechObservation(
            durationMs: runMs,
            wordCount: nil,
            isEcho: false,
            agentSpeakingElapsedMs: speakingElapsed
        )
        guard classifier.classify(speech: obs) == .interrupt else { return }
        stateLock.lock()
        onsetRunFired = true
        stateLock.unlock()
        trace.record("onset barge-in: run=\(runMs)ms → interrupt")
        feed(.speechStarted)
    }

    private func onTranscript(_ transcript: Transcript) {
        stateLock.lock()
        let isConnected = connected
        stateLock.unlock()
        guard isConnected else { return }

        switch transcript {
        case .partial(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            stateLock.lock()
            if speechBurstStartMs == 0 { speechBurstStartMs = Self.nowMs() }
            let burstMs = UInt32(clamping: Self.nowMs() - speechBurstStartMs)
            let speakingElapsed: UInt32? = speakingStartMs > 0
                ? UInt32(clamping: Self.nowMs() - speakingStartMs) : nil
            stateLock.unlock()
            // Only genuine interruptions become machine events; the
            // classifier (Rust, evidence-locked thresholds) decides.
            // Text-domain echo detection is DELIBERATELY absent (Asger,
            // 2026-07-19): own-voice re-entry has never been observed on
            // this platform, and the v1-inherited filter only produced
            // false positives (it ate a genuine barge-in whose words
            // mirrored the greeting). isEcho stays false until echo is
            // actually observed in a trace — re-add on evidence, not lore.
            let obs = SpeechObservation(
                durationMs: burstMs,
                wordCount: UInt32(trimmed.split(separator: " ").count),
                isEcho: false,
                agentSpeakingElapsedMs: speakingElapsed
            )
            let verdict = classifier.classify(speech: obs)
            if verdict == .interrupt {
                trace.record("barge-in: partial \"\(Self.clip(trimmed))\" burst=\(burstMs)ms → interrupt")
                feed(.speechStarted)
            } else {
                // Deaf-window evidence (doc 16 Q2): the b6 drop could not be
                // diagnosed because sub-threshold partials were invisible —
                // "no partials arrived" vs "arrived and were ignored" was
                // undecidable. Log every partial until that question closes.
                trace.record("partial (ignored): \"\(Self.clip(trimmed))\" burst=\(burstMs)ms")
            }
        case .final(let text, _, _, _):
            stateLock.lock()
            let hadPartials = speechBurstStartMs != 0
            speechBurstStartMs = 0
            let speakingElapsed: UInt32? = speakingStartMs > 0
                ? UInt32(clamping: Self.nowMs() - speakingStartMs) : nil
            stateLock.unlock()
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            // Deterministic end-intent BEFORE the model (the 1.5B can also
            // end via the injected tool; the phrase path is instant).
            if isEndIntent(trimmed) {
                trace.record("end intent: \"\(Self.clip(trimmed))\"")
                dispatchEndTool(utterance: trimmed)
                return
            }
            // Finals-only substrate adaptation (browser-sim Whisper sends no
            // partials): mid-THINKING/SPEAKING the machine yields only to a
            // classified SpeechStarted — which the partial path produces on
            // hardware. Without partials a final here would be silently
            // dropped (2026-07-24 sim run: "can't interrupt" + "doesn't
            // answer"). Synthesize the missing signal: estimate the burst
            // from word count and let the classifier + the machine's
            // EXISTING cancel/supersede paths rule. Hardware is untouched —
            // its partials make hadPartials true.
            if !hadPartials {
                machineLock.lock()
                let st = loop.state()
                machineLock.unlock()
                if st == .thinking || st == .speaking {
                    let words = trimmed.split(separator: " ").count
                    let obs = SpeechObservation(
                        durationMs: UInt32(clamping: min(5000, words * 320)),
                        wordCount: UInt32(words),
                        isEcho: false,
                        agentSpeakingElapsedMs: st == .speaking ? speakingElapsed : nil
                    )
                    if classifier.classify(speech: obs) == .interrupt {
                        trace.record("finals-only barge-in: \"\(Self.clip(trimmed))\" est=\(words * 320)ms → interrupt")
                        feed(.speechStarted)
                    } else {
                        trace.record("finals-only final (ignored by classifier): \"\(Self.clip(trimmed))\"")
                    }
                }
            }
            stateLock.lock()
            turnStartMs = Self.nowMs()
            firstChunkLogged = false
            firstAudioLogged = false
            stateLock.unlock()
            trace.record("user: \"\(Self.clip(trimmed, 80))\"")
            feed(.transcriptReady(text: trimmed))
        }
    }

    // ── The machine pump ─────────────────────────────────────────────────

    private func feed(_ event: ConversationEvent) {
        machineLock.lock()
        let effects = loop.handle(event: event)
        let state = loop.state()
        machineLock.unlock()
        switch event {
        case .replyChunk, .speechCompleted:
            break // spans cover these; per-segment rows are noise
        default:
            trace.record("machine: \(Self.eventName(event)) → \(state)")
        }
        for effect in effects { execute(effect) }
    }

    private static func eventName(_ event: ConversationEvent) -> String {
        switch event {
        case .start: return "start"
        case .stop: return "stop"
        case .speechStarted: return "speechStarted"
        case .utteranceFinished: return "utteranceFinished"
        case .transcriptReady: return "transcriptReady"
        case .replyReady: return "replyReady"
        case .replySilent: return "replySilent"
        case .replyChunk: return "replyChunk"
        case .replyFinished: return "replyFinished"
        case .speechCompleted: return "speechCompleted"
        case .speakRequested: return "speakRequested"
        case .timerFired: return "timerFired"
        }
    }

    private func execute(_ effect: ConversationEffect) {
        switch effect {
        case .transcribe:
            // Baseline ears deliver text straight from Listening — the
            // machine never emits Transcribe on that path; a no-op keeps
            // the executor total.
            break

        case .beginInference(let text):
            onAssistantEvent(.userSpoke(transcript: text))
            appendHistoryLocked(.userText(text: text, timestampMs: Self.nowMs()))
            let brain = brain
            let instructions = composedInstructions()
            let tools = brainTools()
            stateLock.lock()
            inferenceGen += 1
            let gen = inferenceGen
            stateLock.unlock()
            inferenceTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let reply = try await brain.runTurn(
                        instructions: instructions,
                        userText: text,
                        tools: tools,
                        execute: { [weak self] name, argsJson in
                            await self?.runTool(name: name, argsJson: argsJson) ?? "tool unavailable"
                        },
                        onToolCalled: { [weak self] name, argsJson in
                            self?.emitToolCalled(name: name, argsJson: argsJson)
                        },
                        onToolResult: { _, _ in /* emitted with ids in runTool */ },
                        onReplyChunk: { [weak self] chunk in
                            guard let self, self.isLiveGeneration(gen) else { return }
                            self.traceFirstChunk()
                            self.feed(.replyChunk(text: chunk))
                        },
                        onStats: { [weak self] stats in
                            self?.trace.record(String(
                                format: "gen: prefill %.2fs (%d tok, reused %d, %@), decode %.2fs (%d tok, %.1f tok/s)",
                                stats.promptSeconds, stats.promptTokens,
                                stats.cacheReusedTokens,
                                stats.cacheDisposition.isEmpty ? "?" : stats.cacheDisposition,
                                stats.generateSeconds, stats.generationTokens,
                                stats.generateSeconds > 0
                                    ? Double(stats.generationTokens) / stats.generateSeconds : 0
                            ))
                        }
                    )
                    guard !Task.isCancelled, self.isLiveGeneration(gen) else { return }
                    if let reply, !reply.isEmpty {
                        // Segments already streamed through the machine;
                        // ONE parity event + history row for the whole
                        // reply (cloud-provider shape).
                        self.trace.record("reply: \"\(Self.clip(reply, 140))\"")
                        self.onAssistantEvent(.assistantSpoke(transcript: reply))
                        self.appendHistoryLocked(.assistantText(text: reply, timestampMs: Self.nowMs()))
                        self.traceTurnDone()
                        self.feed(.replyFinished)
                    } else {
                        self.trace.record("reply: silent")
                        self.feed(.replyFinished)
                    }
                } catch is CancellationError {
                    // Superseded — the machine already moved on.
                } catch {
                    guard self.isLiveGeneration(gen) else { return }
                    self.trace.record("inference error: \(error)")
                    self.onAssistantEvent(.error(kind: "inference", message: String(describing: error)))
                    let apology = (error as? SpeakableBrainError)?.spokenMessage
                        ?? "Sorry, I ran into a problem."
                    self.onAssistantEvent(.assistantSpoke(transcript: apology))
                    self.appendHistoryLocked(.assistantText(text: apology, timestampMs: Self.nowMs()))
                    // Chunk + finished works from THINKING and SPEAKING
                    // alike (a late tool-loop failure lands mid-stream).
                    self.feed(.replyChunk(text: apology))
                    self.feed(.replyFinished)
                }
            }

        case .cancelInference:
            stateLock.lock()
            inferenceGen += 1 // gate: stragglers from this generation die
            stateLock.unlock()
            inferenceTask?.cancel()
            trace.record("inference cancelled")

        case .speak(let text):
            enqueueSpeak(text)

        case .cancelSpeech:
            stateLock.lock()
            speechQueue.removeAll()
            currentSegment = ""
            pumpRunning = false // a cancelled pump never reaches its drain
            speakingStartMs = 0
            stateLock.unlock()
            speakPump?.cancel()
            trace.record("speech cancelled")
            Task { [audio] in await audio.cancelSpeak() }
            if let voiceSynth {
                Task { [transport] in
                    await voiceSynth.cancel()
                    transport.cancelOutgoingAudio()
                }
            }

        case .scheduleTimer(let timer, let ms):
            stateLock.lock()
            timers[timer]?.cancel()
            timers[timer] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                if Task.isCancelled { return }
                self?.feed(.timerFired(timer: timer))
            }
            stateLock.unlock()

        case .cancelTimer(let timer):
            stateLock.lock()
            timers[timer]?.cancel()
            timers[timer] = nil
            stateLock.unlock()

        case .requestSleep:
            trace.record("silence timeout → sleep")
            WakeLedger.shared.note("sleep: silence timeout")
            onSilenceTimeout()
        }
    }

    /// Append a segment to the single-owner serial queue; start the pump if
    /// idle. One `SpeechCompleted` per segment (the machine counts).
    private func enqueueSpeak(_ text: String) {
        stateLock.lock()
        speechQueue.append(text)
        let startPump = !pumpRunning
        if startPump {
            pumpRunning = true
            speakingStartMs = Self.nowMs()
            lastSpokenText = text
        } else {
            // Same logical utterance — the echo filter compares against
            // everything currently being said.
            lastSpokenText += " " + text
        }
        stateLock.unlock()
        traceFirstAudio()
        guard startPump else { return }
        speakPump = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.stateLock.lock()
                guard !self.speechQueue.isEmpty else {
                    self.pumpRunning = false
                    self.speakingStartMs = 0
                    self.stateLock.unlock()
                    return
                }
                let segment = self.speechQueue.removeFirst()
                self.currentSegment = segment
                self.stateLock.unlock()
                await self.speakSegment(segment)
                self.stateLock.lock()
                self.currentSegment = ""
                self.stateLock.unlock()
                if Task.isCancelled { return }
                self.feed(.speechCompleted)
            }
        }
    }

    /// One segment through the configured mouth. Kokoro path (doc 19 K3):
    /// synthesize with streaming emit into the transport's outgoing-audio
    /// player (starts audible at the FIRST chunk — the K2 spike's
    /// requirement), then wait out the playback remainder so the pump's
    /// SpeechCompleted keeps honest machine accounting. Any failure or
    /// not-ready state falls back to the system voice for THAT segment.
    private func speakSegment(_ segment: String) async {
        if let synth = voiceSynth, await synth.isReady() {
            trace.record("mouth: kokoro segment begin (\(segment.count) chars)")
            let t0 = Self.nowMs()
            let seconds = await synth.synthesize(segment) { [transport] pcm, rate in
                transport.sendOutgoingAudioChunk(sampleRate: rate, pcmBytes: pcm)
            }
            trace.record("mouth: kokoro synth returned \(seconds.map { String(format: "%.2fs audio", $0) } ?? "nil") in \(Self.nowMs() - t0)ms")
            if let seconds {
                // Core-owned accounting (speak.rs) — tail pad included; the
                // direct-speak path waits with the same arithmetic.
                let remainMs = speakPlaybackRemainderMs(audioSeconds: seconds, elapsedMs: Self.nowMs() - t0)
                if remainMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainMs) * 1_000_000)
                }
                trace.record("mouth: kokoro segment done")
                return
            }
            // A CANCELLED synthesis must never fall back — the b24 trace
            // showed barge-ins re-speaking the interrupted segment in the
            // system voice. Only genuine failures fall through.
            if Task.isCancelled { return }
            trace.record("kokoro synthesis failed — system voice fallback for segment")
        }
        if Task.isCancelled { return }
        let result = await audio.speak(segment)
        trace.record("mouth: system speak returned \(result)")
    }

    // ── Tools ────────────────────────────────────────────────────────────

    private func brainTools() -> [LocalBrainTool] {
        var mapped = config.tools.map { tool in
            LocalBrainTool(
                name: tool.name,
                description: tool.description,
                schemaJson: tool.schema.flatMap { Self.jsonString($0) }
            )
        }
        // Cloud parity: the built-in device-info tool (core-owned name +
        // description; the cloud core injects the same one). Answered in
        // runTool below — the customer's handler never sees it.
        if config.includeDeviceInfoTool {
            mapped.append(LocalBrainTool(
                name: deviceInfoToolName(),
                description: deviceInfoToolDescription(),
                schemaJson: nil
            ))
        }
        return mapped
    }

    /// The DSP-20 glasses-state line — the same core builder the cloud path
    /// answers get_device_info with. Static capabilities today; the display
    /// flag is live from the transport, display-shown tracking lands with
    /// the local display phase.
    private func glassesStateLine() -> String {
        glassesStateContextLine(
            vendor: "Meta",
            device: "smart glasses",
            camera: true,
            microphone: true,
            speaker: true,
            display: transport.isDisplayCapable(),
            displayShown: false,
            displayKind: nil
        )
    }

    private func runTool(name: String, argsJson: String) async -> String {
        // Built-in device-info: intercepted here exactly as the cloud core
        // intercepts it — the customer's tool handler never sees the call.
        if name == deviceInfoToolName() {
            let line = glassesStateLine()
            trace.record("tool result: get_device_info (built-in) → \"\(Self.clip(line, 80))\"")
            return line
        }
        guard let tool = config.tools.first(where: { $0.name == name }) else {
            return "unknown tool"
        }
        let callId = "local_call_\(UUID().uuidString)"
        let args = JSONValue.parse(argsJson) ?? .object([:])
        let startNs = DispatchTime.now().uptimeNanoseconds
        let output: String
        var isError = false
        do {
            switch try await tool.body(args) {
            case .ok(let text): output = text
            case .err(let message): output = message; isError = true
            }
        } catch {
            output = "tool threw: \(error)"
            isError = true
        }
        let durationMs = Int64((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000)
        trace.record("tool result: \(name) \(isError ? "ERROR " : "")(\(durationMs)ms) → \"\(Self.clip(output, 100))\"")
        appendHistoryLocked(.toolInvocation(name: name, callId: callId, argsJson: argsJson, timestampMs: Self.nowMs()))
        appendHistoryLocked(.toolReturn(callId: callId, output: output, timestampMs: Self.nowMs()))
        onAssistantEvent(.toolResult(callId: callId, name: name, output: output, isError: isError, durationMs: durationMs))
        return output
    }

    private func emitToolCalled(name: String, argsJson: String) {
        trace.record("tool called: \(name) \(Self.clip(argsJson, 100))")
        let args = JSONValue.parse(argsJson) ?? .object([:])
        onAssistantEvent(.toolCalled(name: name, args: args, callId: "local_call_pending"))
    }

    // ── End intent (deterministic, pre-inference) ────────────────────────

    private func isEndIntent(_ text: String) -> Bool {
        let normalized = Self.normalizePhrase(text)
        if normalized.isEmpty { return false }
        if config.sleepPhrases.contains(where: { Self.normalizePhrase($0) == normalized }) { return true }
        if Self.defaultEndPhrases.contains(normalized) { return true }
        let negated = ["dont", "not", "never"].contains { " \(normalized) ".contains(" \($0) ") }
        if !negated && Self.endRequestSubstrings.contains(where: { normalized.contains($0) }) { return true }
        return false
    }

    private func dispatchEndTool(utterance: String) {
        onAssistantEvent(.userSpoke(transcript: utterance))
        appendHistoryLocked(.userText(text: utterance, timestampMs: Self.nowMs()))
        guard let tool = config.tools.first(where: { $0.name == endConversationToolName() }) else { return }
        Task {
            _ = try? await tool.body(.object([:]))
        }
    }

    // ── Runtime surface ──────────────────────────────────────────────────

    func say(_ text: String) async {
        guard isConnected() else { return }
        onAssistantEvent(.assistantSpoke(transcript: text))
        appendHistoryLocked(.assistantText(text: text, timestampMs: Self.nowMs()))
        feed(.speakRequested(text: text))
    }

    func greet(_ prompt: String?) async {
        guard isConnected() else { return }
        let t0 = Self.nowMs()
        let instructions = composedInstructions()
        // Latency budget: the greeting is the wake ACK — it must land fast.
        // A warm compose (~1s) always wins this race; a cold start (model
        // still loading + full prefill — 10s measured on iPhone 12,
        // 2026-07-25) loses it, and the canned phrase speaks at the
        // deadline instead. The abandoned compose is cancelled; the
        // post-greeting prefix warm still readies the cache for turn one.
        let tools = brainTools()
        stateLock.lock()
        let warmed = brainWarmed
        stateLock.unlock()
        if !warmed {
            trace.record("greeting: brain still warming — instant canned ack")
        }
        let composed: String? = !warmed ? nil : await withTaskGroup(of: String?.self) { group in
            group.addTask { [brain] in
                (try? await brain.composeGreeting(instructions: instructions, prompt: prompt, tools: tools))
                    .flatMap { $0 }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if composed == nil {
            trace.record("greeting budget hit (2500ms) — canned ack while the model warms")
        }
        let text = composed ?? config.fallbackGreeting ?? "Hi — how can I help?"
        trace.record("greeting composed in \(Self.nowMs() - t0)ms: \"\(Self.clip(text, 80))\"")
        WakeLedger.shared.note("greet: composed in \(Self.nowMs() - t0)ms")
        onAssistantEvent(.assistantSpoke(transcript: text))
        appendHistoryLocked(.assistantText(text: text, timestampMs: Self.nowMs()))
        feed(.speakRequested(text: text))
    }

    func includeImage(uri: String, prompt: String?) async {
        // Capability honesty: no vision on this tier yet (doc 14 —
        // model-ladder phase). Never fake it.
        onAssistantEvent(.error(
            kind: "vision_unsupported",
            message: "The local model on this device doesn't support images yet."
        ))
    }

    func sendVideoFrame(_ frame: Data, mimeType: String) async {
        onAssistantEvent(.error(kind: "video_input_unsupported", message: "local tier has no video input"))
    }

    func injectSystemContext(_ text: String) { /* v2 later: fold into instructions */ }
    func setReasoningEffort(_ effort: ReasoningEffort) {}
    func setVoice(_ voice: String) {}
    func setModel(_ model: String) {}

    func updateInstructions(_ instructions: String) {
        stateLock.lock()
        currentInstructions = instructions
        stateLock.unlock()
    }

    func cancelSpeak() {
        stateLock.lock()
        speechQueue.removeAll()
        currentSegment = ""
        pumpRunning = false
        speakingStartMs = 0
        stateLock.unlock()
        speakPump?.cancel()
        Task { [audio] in await audio.cancelSpeak() }
        if let voiceSynth {
            Task { [transport] in
                await voiceSynth.cancel()
                transport.cancelOutgoingAudio()
            }
        }
    }

    func conversationHistory(limit: Int) -> [Turn] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(history.suffix(limit))
    }

    func clearHistory() {
        stateLock.lock()
        history.removeAll()
        stateLock.unlock()
        Task { [brain] in await brain.clearHistory() }
    }

    func appendHistory(_ turn: Turn) { appendHistoryLocked(turn) }

    func replaceHistory(_ turns: [Turn]) {
        stateLock.lock()
        history = Array(turns.suffix(config.historyCap))
        stateLock.unlock()
    }

    // ── Small helpers ────────────────────────────────────────────────────

    private func isConnected() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connected
    }

    /// The composed system prompt the brain actually receives — the local
    /// tier's answer to the alignment layer cloud vendors bake in:
    ///   [conduct floor] + [developer instructions | default] + [device-info note]
    /// Every string is core-owned (uniffi) so the text cannot drift per
    /// platform; the floor is config-gated (localConductFloor, default ON).
    private func composedInstructions() -> String {
        let dev = currentInstructionsSnapshot()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if config.localConductFloor { parts.append(localConductFloor()) }
        parts.append(dev.isEmpty ? localDefaultInstructions() : dev)
        if config.includeDeviceInfoTool {
            let note = config.deviceInfoNote ?? defaultDeviceInfoNote()
            if !note.isEmpty { parts.append(note) }
        }
        return parts.joined(separator: "\n\n")
    }

    private func currentInstructionsSnapshot() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentInstructions
    }

    private func appendHistoryLocked(_ turn: Turn) {
        stateLock.lock()
        history.append(turn)
        while history.count > config.historyCap { history.removeFirst() }
        stateLock.unlock()
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // ── Trace helpers (per-turn latency spans) ───────────────────────────

    private func isLiveGeneration(_ gen: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return gen == inferenceGen
    }

    private func traceFirstChunk() {
        stateLock.lock()
        let start = turnStartMs
        let log = !firstChunkLogged && start > 0
        firstChunkLogged = true
        stateLock.unlock()
        if log { trace.record("first sentence ready +\(Self.nowMs() - start)ms") }
    }

    private func traceFirstAudio() {
        stateLock.lock()
        let start = turnStartMs
        let log = !firstAudioLogged && start > 0
        firstAudioLogged = true
        stateLock.unlock()
        if log { trace.record("first audio starts +\(Self.nowMs() - start)ms") }
    }

    private func traceTurnDone() {
        stateLock.lock()
        let start = turnStartMs
        turnStartMs = 0
        stateLock.unlock()
        if start > 0 { trace.record("generation done +\(Self.nowMs() - start)ms") }
    }

    private static func clip(_ s: String, _ max: Int = 40) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    private static func jsonString(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizePhrase(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }

    private static let defaultEndPhrases: Set<String> = [
        "goodbye", "bye", "bye bye", "thanks im done", "im done",
        "thats all", "thats all for now", "see you later", "im good",
        "thank you goodbye", "thanks bye", "stop",
    ]

    private static let endRequestSubstrings: [String] = [
        "end this conversation", "end the conversation",
        "stop this conversation", "stop the conversation",
        "end this chat", "end the chat", "stop listening", "go to sleep",
    ]
}
