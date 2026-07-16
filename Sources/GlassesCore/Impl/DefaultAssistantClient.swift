import Foundation

// `glasses.assistant` impl. Singleton-active session; thin shell over the
// Rust realtime core via `RealtimeCoreProvider` (OpenAI through the managed
// gateway) or `MockAssistantProvider`.
//
// Lifecycle ownership:
//   - DefaultAssistantClient: singleton-active guard, provider dispatch,
//     gateway backing, event-emitter wiring
//   - DefaultAssistantSession: the 8-state lifecycle — transition DECISIONS
//     come from the core gate (realtime/lifecycle.rs, shared with Android);
//     this file keeps only the effect sequences (pinned as the C3
//     invariants in the parity plan)
//   - RealtimeCoreProvider / MockAssistantProvider: WS + audio pump + tool
//     dispatch seams
//
// Mirrors `android-library/.../impl/DefaultAssistantClient.kt` (post-C2).
// C3b follow-ups (documented in ios-c3-shell-workorder.md): live-config
// overlay (AssistantConfigClient port), sleepOnPhrase voice registration,
// sim gateway-token surface, DSP-20 glasses-state wiring (needs Phase-D
// display state).

internal final class DefaultAssistantClient: AssistantClient, @unchecked Sendable {

    private let audio: any AudioClient
    private let transport: any GlassesTransport
    private let environment: ExtentosEnvironment
    /// Gateway bearer resolver — sim gateway token (dev) or attest JWT
    /// (beta/prod). nil = not available yet (connect fails soft + retries
    /// on the next wake). GATEWAY ONLY — never attach this to the
    /// live-config fetch: the dogfood lane resolves it to the baked
    /// project key, which /api/assistant-config rejects as an invalid
    /// attest JWT (401 → silent fallback to hard defaults; the 2026-07-15
    /// dashboard-config audit — Grok/voice/wake-sound never applied on
    /// iOS while Android, which wires the attest JWT, worked).
    private let gatewayToken: @Sendable () -> String?
    /// Cached attestation JWT for the live-config fetch, or nil
    /// pre-attestation / in dev (the route allows a missing bearer).
    /// Mirrors Kotlin AssistantConfigClient's getJWT contract. Async —
    /// AttestClient is an actor.
    private let attestJWT: @Sendable () async -> String?
    /// Project app id for the live-config fetch (dashboard Agent tab).
    private let appId: String?
    /// Shared named-sound registry — dashboard sounds land here at session
    /// start (named-sounds-registry decision). Nil in bare tests.
    private let soundRegistry: SoundRegistry?
    /// Voice client for sleepOnPhrase registrations; nil in bare tests.
    private let voice: (any VoiceClient)?
    /// Emit an `AssistantEvent` to the shared event-logger.
    private let onAssistantEvent: @Sendable (AssistantEvent) -> Void

    private let stateLock = NSLock()
    // STRONG ref (parity with Android AtomicReference<DefaultAssistantSession>).
    // Holding it weakly let the session deallocate the moment the customer
    // discarded the returned value (`_ = try await assistant.start(...)`),
    // silently killing the running realtime session — the idiomatic call
    // shape must keep the assistant alive. Cleared in release() on stop, so
    // no leak and no retain cycle (SingletonGuard.owner stays weak).
    private var activeSessionRef: DefaultAssistantSession?
    private var singletonGuardRef: SingletonGuard?

    init(
        audio: any AudioClient,
        transport: any GlassesTransport,
        environment: ExtentosEnvironment = .development,
        gatewayToken: @escaping @Sendable () -> String? = { nil },
        attestJWT: @escaping @Sendable () async -> String? = { nil },
        appId: String? = nil,
        voice: (any VoiceClient)? = nil,
        soundRegistry: SoundRegistry? = nil,
        onAssistantEvent: @escaping @Sendable (AssistantEvent) -> Void = { _ in }
    ) {
        self.audio = audio
        self.transport = transport
        self.environment = environment
        self.gatewayToken = gatewayToken
        self.attestJWT = attestJWT
        self.appId = appId
        self.soundRegistry = soundRegistry
        self.voice = voice
        self.onAssistantEvent = onAssistantEvent
        self.singletonGuardRef = nil
        self.singletonGuardRef = SingletonGuard(owner: self)
    }

    // MARK: - AssistantClient

    @discardableResult
    func start(
        provider: AssistantProvider,
        _ configure: (AssistantConfigBuilder) -> Void
    ) async throws -> any AssistantSession {
        let builder = AssistantConfigBuilder()
        configure(builder)
        let config = builder.build(provider: provider)
        let session = createSessionInternal(config: config)
        try await session.start()
        return session
    }

    func createSession(config: AssistantConfig) -> any AssistantSession {
        createSessionInternal(config: config)
    }

    func stop() async {
        stateLock.lock()
        let current = activeSessionRef
        stateLock.unlock()
        await current?.stop()
    }

    var activeSession: (any AssistantSession)? {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeSessionRef
    }

    // MARK: - Internal helpers

    private func createSessionInternal(config: AssistantConfig) -> DefaultAssistantSession {
        stateLock.lock()
        let guardRef = singletonGuardRef!
        stateLock.unlock()
        let fetcher = AssistantConfigClient(
            endpoint: AssistantConfigClient.defaultEndpoint(environment: environment),
            appId: appId,
            getJWT: attestJWT
        )
        return DefaultAssistantSession(
            config: config,
            audio: audio,
            transport: transport,
            backing: .gateway(environment: environment, authToken: gatewayToken),
            voice: voice,
            configFetcher: { await fetcher.fetch() },
            soundRegistry: soundRegistry,
            onAssistantEvent: onAssistantEvent,
            singletonGuard: guardRef
        )
    }

    fileprivate func claim(session: DefaultAssistantSession) throws {
        stateLock.lock()
        let existing = activeSessionRef
        if let existing, existing !== session, existing.state.current != .stopped {
            stateLock.unlock()
            throw AssistantError.alreadyActive
        }
        activeSessionRef = session
        stateLock.unlock()
    }

    fileprivate func release(session: DefaultAssistantSession) {
        stateLock.lock()
        if activeSessionRef === session {
            activeSessionRef = nil
        }
        stateLock.unlock()
    }
}

/// Tiny helper the session uses to register/clear itself as the active one.
internal final class SingletonGuard: @unchecked Sendable {
    private weak var owner: DefaultAssistantClient?

    init(owner: DefaultAssistantClient) {
        self.owner = owner
    }

    func claim(_ session: DefaultAssistantSession) throws {
        try owner?.claim(session: session)
    }

    func release(_ session: DefaultAssistantSession) {
        owner?.release(session: session)
    }
}

/// Concrete `AssistantSession`. Transition DECISIONS are core-owned
/// (`assistantLifecycleGate`); this type runs the effect sequences.
internal final class DefaultAssistantSession: AssistantSession, @unchecked Sendable {

    let config: AssistantConfig
    private let audio: any AudioClient
    private let transport: any GlassesTransport
    private let backing: AssistantBacking
    private let voice: (any VoiceClient)?
    private let configFetcher: @Sendable () async -> LiveAssistantConfig?
    private let onAssistantEvent: @Sendable (AssistantEvent) -> Void
    private let singletonGuard: SingletonGuard

    private let stateRef: MutableState<AssistantState>
    private var runtime: (any AssistantProviderRuntime)?
    /// The dashboard's wake-chime URL, resolved alongside the overlay (no
    /// code-set counterpart — dashboard-only knob).
    private var resolvedWakeSoundUrl: String?
    private var resolvedWakeSoundDisabled = false
    private let soundRegistry: SoundRegistry?
    private var sleepPhraseRegistrations: [any VoiceRegistration] = []

    init(
        config: AssistantConfig,
        audio: any AudioClient,
        transport: any GlassesTransport,
        backing: AssistantBacking,
        voice: (any VoiceClient)? = nil,
        configFetcher: @escaping @Sendable () async -> LiveAssistantConfig? = { nil },
        soundRegistry: SoundRegistry? = nil,
        onAssistantEvent: @escaping @Sendable (AssistantEvent) -> Void,
        singletonGuard: SingletonGuard
    ) {
        self.config = config
        self.audio = audio
        self.transport = transport
        self.backing = backing
        self.voice = voice
        self.configFetcher = configFetcher
        self.soundRegistry = soundRegistry
        self.onAssistantEvent = onAssistantEvent
        self.singletonGuard = singletonGuard
        self.stateRef = MutableState(AssistantState.idle)
    }

    var state: any ObservableState<AssistantState> { stateRef }

    // MARK: - The core gate

    /// Consult the core-owned lifecycle gate (realtime/lifecycle.rs — the
    /// canonical transition table both shells share). True = proceed;
    /// false = idempotent no-op; throws the mapped error on Fail.
    private func gate(_ op: LifecycleOp) throws -> Bool {
        switch assistantLifecycleGate(op: op, state: stateRef.current.toLifecycleState()) {
        case .proceed:
            return true
        case .noOp:
            return false
        case .fail(let kind, _):
            switch kind {
            case .sessionEnded: throw AssistantError.sessionEnded
            case .notReady: throw AssistantError.notReady
            }
        }
    }

    // MARK: - start / wake / sleep / stop (effect ordering = C3 invariants)

    func start() async throws {
        try await lifecycleSerializer.runThrowing { [self] in
            guard try gate(.start) else { return }

            // Singleton claim BEFORE state transition — throws if another
            // session is active. No state side-effects on failure.
            try singletonGuard.claim(self)

            do {
                // Live-config overlay: fill any model/voice/compaction the
                // developer left unset from the dashboard (code-set wins;
                // fetch failure/timeout -> code + hard defaults). The C1
                // invariant: only developer-null fields are filled.
                let live = await resolveLiveOverlay()
                let rt = await createRuntime(overlay: live)
                try await rt.start()
                runtime = rt
                // Dashboard wake chime, downloaded + decoded off-thread;
                // best-effort (default chime on any failure). Skipped when
                // the dashboard picked "None" — nothing will play anyway.
                if !resolvedWakeSoundDisabled {
                    rt.applyWakeSound(resolvedWakeSoundUrl)
                }
                // Named sounds: the project's uploaded library becomes
                // playSound(name)-able (named-sounds-registry decision).
                registerDashboardSounds(live)
                // Sleep phrases stay registered across wake/sleep cycles;
                // sleep() from a non-sleepable state is a core-gate no-op.
                // (Kotlin scopes these WhenActive for log hygiene; the iOS
                // VoiceScope port is a flagged follow-up.)
                registerSleepPhrases()
                stateRef.set(.dormant)

                // startActive=true skips Dormant — open immediately.
                if config.startActive {
                    try await doWakeLocked()
                }
            } catch {
                sleepPhraseRegistrations.forEach { $0.cancel() }
                sleepPhraseRegistrations.removeAll()
                runtime = nil
                stateRef.set(.stopped)
                singletonGuard.release(self)
                throw Self.asAssistantError(error)
            }
        }
    }

    func wake() async throws {
        try await lifecycleSerializer.runThrowing { [self] in
            guard try gate(.wake) else { return }
            try await doWakeLocked()
        }
    }

    private func doWakeLocked() async throws {
        stateRef.set(.activating)
        // Wake chime the moment activation begins — it fills the connect
        // wait and queues ahead of the greeting on the same audio path.
        // Dashboard "None" (wakeSoundDisabled) silences it; code-set
        // wakeSoundEnabled=false also wins, independently.
        if config.wakeSoundEnabled && !resolvedWakeSoundDisabled {
            runtime?.playWakeSound()
        }
        do {
            guard let rt = runtime else {
                throw AssistantError.notReady
            }
            try await rt.connect()
            stateRef.set(.active)
            // Automatic greeting — wake()-only (reconnects don't pass
            // through here), generated OUT-OF-BAND from the memory preamble
            // + directive. Fire-and-forget.
            switch config.greeting {
            case .off:
                break
            case .default:
                Task { await rt.greet(nil) }
            case .custom(let directive):
                Task { await rt.greet(directive) }
            }
            // onWake hook fire-and-forget; errors are events, never
            // state rollbacks.
            if let hook = config.onWake {
                let emit = onAssistantEvent
                let sessionRef: any AssistantSession = self
                Task {
                    do {
                        try await hook(sessionRef)
                    } catch {
                        emit(.error(kind: "wake_hook", message: "onWake hook threw: \(error)"))
                    }
                }
            }
        } catch {
            // Connect failed — back to Dormant so wake() can be retried.
            stateRef.set(.dormant)
            throw Self.asAssistantError(error)
        }
    }

    func sleep() async throws {
        try await lifecycleSerializer.runThrowing { [self] in
            guard try gate(.sleep) else { return }
            stateRef.set(.sleeping)
            await runtime?.disconnect()
            stateRef.set(.dormant)
            // "This active turn ended, can be re-woken" — distinct from the
            // terminal sessionEnded.
            onAssistantEvent(.wentDormant)
            if let hook = config.onSleep {
                let emit = onAssistantEvent
                let sessionRef: any AssistantSession = self
                Task {
                    do {
                        try await hook(sessionRef)
                    } catch {
                        emit(.error(kind: "sleep_hook", message: "onSleep hook threw: \(error)"))
                    }
                }
            }
        }
    }

    func stop() async {
        await lifecycleSerializer.runNonThrowing { [self] in
            guard (try? gate(.stop)) == true else { return }
            stateRef.set(.stopping)
            sleepPhraseRegistrations.forEach { $0.cancel() }
            sleepPhraseRegistrations.removeAll()
            await runtime?.stop()
            runtime = nil
            stateRef.set(.stopped)
            singletonGuard.release(self)
            onAssistantEvent(.sessionEnded(reason: .user, message: nil))
        }
    }

    // MARK: - Conversation surface

    private func activeRuntime() throws -> any AssistantProviderRuntime {
        let s = stateRef.current
        guard let rt = runtime else {
            throw s == .stopped || s == .stopping ? AssistantError.sessionEnded : AssistantError.notReady
        }
        guard s == .active || s == .reconnecting else {
            throw s == .stopped || s == .stopping ? AssistantError.sessionEnded : AssistantError.notReady
        }
        return rt
    }

    func say(_ text: String) async throws {
        await (try activeRuntime()).say(text)
    }

    func greet(_ prompt: String?) async throws {
        await (try activeRuntime()).greet(prompt)
    }

    func includeImage(uri: String, prompt: String?) async throws {
        await (try activeRuntime()).includeImage(uri: uri, prompt: prompt)
    }

    func setReasoningEffort(_ effort: ReasoningEffort) async throws {
        (try activeRuntime()).setReasoningEffort(effort)
    }

    func setVoice(_ voice: String) async throws {
        (try activeRuntime()).setVoice(voice)
    }

    func setModel(_ model: String) async throws {
        (try activeRuntime()).setModel(model)
    }

    func updateInstructions(_ instructions: String) async throws {
        (try activeRuntime()).updateInstructions(instructions)
    }

    func cancelSpeak() async {
        runtime?.cancelSpeak()
    }

    func conversationHistory(limit: Int) -> [Turn] {
        runtime?.conversationHistory(limit: limit) ?? []
    }

    func clearHistory() {
        runtime?.clearHistory()
    }

    func appendHistory(_ turn: Turn) {
        runtime?.appendHistory(turn)
    }

    func replaceHistory(_ turns: [Turn]) {
        runtime?.replaceHistory(turns)
    }

    private func registerSleepPhrases() {
        guard let voice else { return }
        for phrase in config.sleepPhrases {
            let reg = voice.onPhrase(phrase: phrase) { [weak self] in
                try? await self?.sleep()
            }
            sleepPhraseRegistrations.append(reg)
        }
    }

    // MARK: - Lifecycle serialization
    //
    // NSLock can't be held across `await`; a single in-flight Task chain
    // serializes lifecycle ops — same effect as Kotlin's lifecycleMutex.

    private actor LifecycleSerializer {
        private var current: Task<Void, Error>?

        func runThrowing(_ body: @escaping @Sendable () async throws -> Void) async throws {
            let prev = current
            let next = Task<Void, Error> {
                _ = try? await prev?.value
                try await body()
            }
            current = next
            try await next.value
        }

        func runNonThrowing(_ body: @escaping @Sendable () async -> Void) async {
            let prev = current
            let next = Task<Void, Error> {
                _ = try? await prev?.value
                await body()
            }
            current = next
            _ = try? await next.value
        }
    }
    private let lifecycleSerializer = LifecycleSerializer()

    // MARK: - Runtime construction

    /// Overlay this project's live dashboard config onto the code-set
    /// values. Skips the network entirely when everything dashboard-driven
    /// is already pinned in code, and for the Mock provider.
    private func resolveLiveOverlay() async -> LiveAssistantConfig? {
        guard case .openAI = config.provider else { return nil }
        // NOTE: the fetch is no longer skipped when every overlay field is
        // code-pinned — the payload now also carries the project's named
        // sounds + the wake-sound "None" flag, which apply regardless.
        // Bounded (4s) + best-effort, so start never blocks on it.
        let live = await configFetcher()
        resolvedWakeSoundUrl = live?.wakeSoundUrl
        resolvedWakeSoundDisabled = live?.wakeSoundDisabled ?? false
        return live
    }

    /// Download + decode the dashboard sound library into the shared
    /// SoundRegistry (fire-and-forget; failures skip the sound). Names
    /// already registered are left alone — code registrations win over
    /// dashboard sounds even when the code registered first.
    private func registerDashboardSounds(_ live: LiveAssistantConfig?) {
        guard let live, !live.sounds.isEmpty, let registry = soundRegistry else { return }
        Task.detached(priority: .utility) {
            let existing = Set(registry.names())
            for sound in live.sounds where !existing.contains(sound.name) {
                if let pcm = await WakeSoundLoader.load(url: sound.url, targetRate: 24_000) {
                    registry.register(name: sound.name, sampleRate: 24_000, pcm: pcm)
                } else {
                }
            }
        }
    }

    private func createRuntime(overlay: LiveAssistantConfig?) -> any AssistantProviderRuntime {
        // Parity with Android (DefaultAssistantClient.createRuntime): when
        // endOnIntent, inject the model-driven end_conversation tool. Its name
        // + description are core-owned (realtime/state.rs); only the body's
        // sleep() binding is platform, so the injection stays shell-side.
        let effectiveConfig = config
            .overlaying(
                compactionModel: config.compactionModel ?? overlay?.compactionModel,
                withinSessionMemory: config.withinSessionMemory ?? overlay?.withinSessionMemory
            )
            .appendingTool(config.endOnIntent ? buildEndConversationTool() : nil)
        switch config.provider {
        case .openAI(let model, let voice, let turnDetection, let reasoningEffort):
            // The managed gateway is the ONLY path (code-direct BYOK
            // removed — Android parity). The token inside the backing is
            // resolved later, at WS open, so a not-yet-authed device still
            // constructs cleanly. Code-set values WIN over the overlay.
            return RealtimeCoreProvider(
                config: effectiveConfig,
                model: model ?? overlay?.realtimeModel,
                voice: voice ?? overlay?.voice,
                turnDetection: turnDetection,
                reasoningEffort: reasoningEffort,
                backing: backing,
                audio: audio,
                transport: transport,
                onAssistantEvent: onAssistantEvent,
                onSilenceTimeout: { [weak self] in
                    guard let self else { return }
                    Task { try? await self.sleep() }
                },
                glassesStateLine: nil  // DSP-20 wiring lands with Phase-D display state.
            )
        case .mock(let behavior):
            return MockAssistantProvider(
                config: effectiveConfig,
                behavior: behavior,
                transport: transport,
                onAssistantEvent: onAssistantEvent
            )
        }
    }

    /// Build the model-driven end_conversation tool (Android parity). Name +
    /// description are core-owned (realtime/state.rs); the body binds this
    /// session's sleep() — the only platform-specific part.
    private func buildEndConversationTool() -> ToolDefinition {
        ToolDefinition(
            name: endConversationToolName(),
            description: endConversationToolDescription(),
            schema: nil,
            blocking: false,
            body: { [weak self] _ in
                // sleep() is state-safe (no-ops if already Dormant); swallow the
                // Stopped/Stopping throw — a sleep after the session ended is harmless.
                try? await self?.sleep()
                return .ok("conversation ended")
            }
        )
    }

    private static func asAssistantError(_ error: any Error) -> any Error {
        if error is AssistantError { return error }
        return AssistantError.networkError(cause: WrappedError(message: "\(error)"))
    }

    struct WrappedError: Error, Sendable { let message: String }
}

private extension AssistantState {
    func toLifecycleState() -> AssistantLifecycleState {
        switch self {
        case .idle: .idle
        case .dormant: .dormant
        case .activating: .activating
        case .active: .active
        case .reconnecting: .reconnecting
        case .sleeping: .sleeping
        case .stopping: .stopping
        case .stopped: .stopped
        }
    }
}

/// Internal contract every provider runtime satisfies. The realtime
/// provider implements the full surface; Mock overrides what it supports
/// and inherits no-op defaults for the rest.
internal protocol AssistantProviderRuntime: Sendable {
    func start() async throws
    func connect() async throws
    func disconnect() async
    func stop() async
    func say(_ text: String) async
    func greet(_ prompt: String?) async
    func includeImage(uri: String, prompt: String?) async
    func injectSystemContext(_ text: String)
    func setReasoningEffort(_ effort: ReasoningEffort)
    func setVoice(_ voice: String)
    func setModel(_ model: String)
    func updateInstructions(_ instructions: String)
    func cancelSpeak()
    func playWakeSound()
    func applyWakeSound(_ url: String?)
    func conversationHistory(limit: Int) -> [Turn]
    func clearHistory()
    func appendHistory(_ turn: Turn)
    func replaceHistory(_ turns: [Turn])
}

/// No-op defaults so minimal runtimes (Mock) only implement what they
/// support — the realtime provider overrides everything.
internal extension AssistantProviderRuntime {
    func connect() async throws {}
    func disconnect() async {}
    func say(_ text: String) async {}
    func greet(_ prompt: String?) async {}
    func includeImage(uri: String, prompt: String?) async {}
    func injectSystemContext(_ text: String) {}
    func setReasoningEffort(_ effort: ReasoningEffort) {}
    func setVoice(_ voice: String) {}
    func setModel(_ model: String) {}
    func updateInstructions(_ instructions: String) {}
    func cancelSpeak() {}
    func playWakeSound() {}
    func applyWakeSound(_ url: String?) {}
    func conversationHistory(limit: Int) -> [Turn] { [] }
    func clearHistory() {}
    func appendHistory(_ turn: Turn) {}
    func replaceHistory(_ turns: [Turn]) {}
}
