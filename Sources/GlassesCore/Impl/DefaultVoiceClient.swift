import Foundation

// DefaultVoiceClient — the `glasses.voice` convenience surface.
//
// Since the shared-core migration (Phase 1) this is a THIN SHELL over the Rust
// `VoiceCore` (extentos-core). The matching/dispatch logic — phrase
// registration, case-insensitive substring matching on FINAL transcripts,
// `stats`/`hints` bookkeeping, the `stops`-cancellation decision, the
// `v_<slug>_<seq>` id — all lives in the core. The shell keeps only what the
// core cannot:
//
//   1. The customer handler lambdas (`handlers`). The core cannot hold or run
//      customer code, so it emits §3b channel-4 dispatch intents
//      (`startHandler` / `cancelHandler`) and this shell runs / cancels the
//      lambdas with native structured concurrency (`Task`).
//   2. The transcription tap. The transport is not migrated until Phase 2, so
//      the shell still owns `audio.transcriptions()` and forwards each FINAL
//      transcript into `core.submitTranscript`.
//   3. The idiomatic `ObservableState` adapters for `hints` / `stats`, seeded
//      by the core's channel-3 observers.
//
// The collector + handler `Task`s are OWNED (`collectorTask`, `runningTasks`)
// and torn down by `shutdown()`. The pre-migration shell leaked them — it
// spawned unstructured `Task`s nothing ever cancelled, not even at library
// shutdown (Phase 1 handoff §A3). `DefaultExtentosGlasses.shutdown()` now
// calls `shutdown()`.
//
// Mirrors `android-library/.../impl/DefaultVoiceClient.kt`. The customer-facing
// `VoiceClient` API is unchanged.
internal final class DefaultVoiceClient: VoiceClient, @unchecked Sendable {
    private let audio: any AudioClient
    private let clock: @Sendable () -> Int64

    // Guards the shell-side maps + the owned Tasks. The core has its own lock;
    // this one only protects `handlers` / `runningTasks` / the collector flags.
    private let lock = NSLock()

    // Customer handler lambdas, keyed by the core-issued hint id. Only
    // `onPhrase` registrations have an entry (`registerHint` is handler-less).
    private var handlers: [String: @Sendable () async -> Void] = [:]

    // In-flight handler Tasks, keyed by hint id then by a per-run token — a
    // collection because re-firing a phrase while its handler still runs
    // starts a second concurrent run (the core emits a second StartHandler
    // for the same id).
    private var runningTasks: [String: [UUID: Task<Void, Never>]] = [:]

    private var collectorStarted = false
    private var collectorTask: Task<Void, Never>?
    private var didShutdown = false

    private let hintsState: MutableState<[VoiceHint]>
    private let statsState: MutableState<[String: VoiceHintStats]>
    private let core: VoiceCore

    init(
        audio: any AudioClient,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.audio = audio
        self.clock = clock
        let hintsState = MutableState<[VoiceHint]>([])
        let statsState = MutableState<[String: VoiceHintStats]>([:])
        self.hintsState = hintsState
        self.statsState = statsState
        // The dispatch observer must call back into `self`; `self` is not yet
        // fully initialised here, so the back-reference is wired after `core`
        // (the last stored property) is assigned.
        let dispatch = DispatchObserverBox()
        self.core = VoiceCore(
            hintsObserver: HintsObserverBox(hintsState),
            statsObserver: StatsObserverBox(statsState),
            dispatchObserver: dispatch
        )
        dispatch.client = self
    }

    var hints: any ObservableState<[VoiceHint]> { hintsState }
    var stats: any ObservableState<[String: VoiceHintStats]> { statsState }

    func onPhrase(
        phrase: String,
        label: String?,
        stops: [String],
        handler: @escaping @Sendable () async -> Void
    ) -> VoiceRegistration {
        // Register the entry and store the handler atomically under `lock`, so
        // a transcript matching the new phrase cannot drive `startHandler`
        // before the handler is reachable (`onIntent` → `startHandler` also
        // takes `lock`). `core.register` emits only the hints/stats observers,
        // never a dispatch intent, so calling it under `lock` cannot re-enter.
        let id: String = lock.withLock {
            let id = core.register(phrase: phrase, label: label, stops: stops, hasHandler: true)
            handlers[id] = handler
            return id
        }
        ensureCollectorStarted()
        return Registration(id: id, client: self)
    }

    func registerHint(
        phrase: String,
        label: String?,
        stops: [String]
    ) -> VoiceRegistration {
        // No handler — the core never emits StartHandler for it, so there is
        // no shell-side race to guard.
        let id = core.register(phrase: phrase, label: label, stops: stops, hasHandler: false)
        ensureCollectorStarted()
        return Registration(id: id, client: self)
    }

    func reportFired(id: String) {
        core.reportFired(id: id, nowMs: clock())
    }

    /// Tear down the owned collector + handler `Task`s. Called from
    /// `DefaultExtentosGlasses.shutdown()`. Idempotent.
    func shutdown() {
        let (collector, running): (Task<Void, Never>?, [Task<Void, Never>]) = lock.withLock {
            didShutdown = true
            let collector = collectorTask
            collectorTask = nil
            let running = runningTasks.values.flatMap { $0.values }
            runningTasks.removeAll()
            return (collector, running)
        }
        collector?.cancel()
        for task in running { task.cancel() }
    }

    // MARK: - Internal

    fileprivate func cancelRegistration(id: String) {
        // Mirrors the pre-migration semantics: removes the hint, but does NOT
        // cancel an already-running handler — it runs to completion or its own
        // stops-cancellation.
        core.cancelRegistration(id: id)
        lock.withLock { _ = handlers.removeValue(forKey: id) }
    }

    // The single transcription collector. Lazy — only subscribes once a phrase
    // is registered, so STT is not started for a voice-less app. Forwards each
    // FINAL transcript into the core, which does the matching.
    private func ensureCollectorStarted() {
        let audio = self.audio
        lock.withLock {
            if collectorStarted || didShutdown { return }
            collectorStarted = true
            collectorTask = Task { [weak self] in
                for await transcript in audio.transcriptions() {
                    if Task.isCancelled { return }
                    guard case .final(let text, _, _, _) = transcript else { continue }
                    guard let self else { return }
                    self.core.submitTranscript(isFinal: true, text: text, nowMs: self.clock())
                }
            }
        }
    }

    // Channel 4 — `StartHandler`: the core matched a phrase. The shell owns the
    // execution. `lock` is held across Task creation + registration so the
    // Task's `defer` self-removal (also under `lock`) cannot run ahead of it.
    fileprivate func startHandler(id: String) {
        lock.withLock {
            guard !didShutdown, let handler = handlers[id] else { return }
            let token = UUID()
            let task = Task { [weak self] in
                defer {
                    if let self {
                        self.core.notifyHandlerFinished(id: id)
                        self.lock.withLock {
                            self.runningTasks[id]?.removeValue(forKey: token)
                            if self.runningTasks[id]?.isEmpty == true {
                                self.runningTasks[id] = nil
                            }
                        }
                    }
                }
                await handler()
            }
            runningTasks[id, default: [:]][token] = task
        }
    }

    // Channel 4 — `CancelHandler`: a `stops` phrase matched. Cancel every
    // in-flight run of `id`; each cancelled Task's `defer` then calls
    // `notifyHandlerFinished` and removes itself from `runningTasks`.
    fileprivate func cancelHandler(id: String) {
        let tasks: [Task<Void, Never>] = lock.withLock {
            Array((runningTasks[id] ?? [:]).values)
        }
        for task in tasks { task.cancel() }
    }

    private struct Registration: VoiceRegistration {
        let id: String
        weak var client: DefaultVoiceClient?
        func cancel() {
            client?.cancelRegistration(id: id)
        }
    }
}

// MARK: - Core observers (§3b channels 3 & 4)

/// Channel 3: the core pushes a fresh full snapshot on every change; the box
/// mirrors it into the `MutableState` the customer observes via `hints`.
private final class HintsObserverBox: HintsObserver, @unchecked Sendable {
    private let state: MutableState<[VoiceHint]>
    init(_ state: MutableState<[VoiceHint]>) { self.state = state }
    func onHints(hints: [VoiceHint]) { state.set(hints) }
}

/// Channel 3: as `HintsObserverBox`, for the `stats` map.
private final class StatsObserverBox: StatsObserver, @unchecked Sendable {
    private let state: MutableState<[String: VoiceHintStats]>
    init(_ state: MutableState<[String: VoiceHintStats]>) { self.state = state }
    func onStats(stats: [String: VoiceHintStats]) { state.set(stats) }
}

/// Channel 4: the core decided a handler should run or be cancelled. `client`
/// is `weak` — the core retains this box, so the box must not retain the
/// client back (that would be a cycle through `core`).
private final class DispatchObserverBox: DispatchObserver, @unchecked Sendable {
    weak var client: DefaultVoiceClient?
    func onIntent(intent: DispatchIntent) {
        switch intent {
        case .startHandler(let id): client?.startHandler(id: id)
        case .cancelHandler(let id): client?.cancelHandler(id: id)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
