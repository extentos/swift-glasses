import Foundation

// `glasses.assistant` customer surface. End-to-end voice provider
// abstraction: OpenAI Realtime through the Extentos MANAGED GATEWAY in v1
// (no app-side key — dev builds reach the gateway via the simulator's
// token, beta/prod builds attest; BYOK is dashboard-managed, swapped in
// server-side) plus Mock for tests. The model owns wake detection, turn
// taking, intent parsing, and confirmation speech — the customer writes
// tool bodies.
//
// Two registration forms (customer-can-skip-it lock):
//   - Sugar — `start(provider:_:) { $0.tool(...) { ... } }`.
//   - Raw — `createSession(config:)` + `session.start()`.
//
// Idiomatic customer code (sugar):
//
//     try await glasses.assistant.start(provider: .openAI()) {
//         $0.instructions = "You are a helpful assistant on smart glasses."
//         $0.tool("take_picture", description: "Take a photo with the glasses camera.") {
//             if let photo = await glasses.camera.capturePhoto().success {
//                 library.add(photo)
//                 return .ok("photo saved")
//             }
//             return .err("camera failed")
//         }
//     }
//
// Singleton-active — at most one active session per `ExtentosGlasses`
// instance; starting a second throws `AssistantError.alreadyActive`.
//
// ## Lifecycle model (Android parity)
//
// A session is a long-lived object with a wake/sleep cycle inside it:
// `start()` sets it up Dormant (or straight to Active with
// `config.startActive`); `wake()` opens the realtime connection;
// `sleep()` closes it but keeps the session (history, tools, hooks)
// ready for the next wake; `stop()` tears everything down for good.
// The canonical transition table lives in the Rust core
// (realtime/lifecycle.rs) — both platforms consult the same gate.
//
// ## Mirror
//
// `android-library/.../assistant/AssistantClient.kt` is the Android parity
// counterpart. API shapes match modulo Swift naming conventions.

public protocol AssistantClient: Sendable {

    /// Sugar form. Build the `AssistantConfig` inline via the trailing
    /// closure, create a session, start it (the session comes up Dormant;
    /// set `$0.startActive = true` to connect immediately). Returns the
    /// session.
    @discardableResult
    func start(
        provider: AssistantProvider,
        _ configure: (AssistantConfigBuilder) -> Void
    ) async throws -> any AssistantSession

    /// Raw form. Create an inactive session from an explicit
    /// `AssistantConfig`; no network activity until
    /// `AssistantSession.start()`.
    func createSession(config: AssistantConfig) -> any AssistantSession

    /// Stop the currently-active session, if any. Idempotent.
    func stop() async

    /// The currently-active session, or nil (singleton-active).
    var activeSession: (any AssistantSession)? { get }
}

/// An assistant session — one configured conversation surface with a
/// wake/sleep cycle. State observable via `state`; lifecycle events also
/// flow through `glasses.runtime.events` as `RuntimeEvent.assistant`.
public protocol AssistantSession: Sendable {

    /// The config used to create this session. Immutable post-construction.
    var config: AssistantConfig { get }

    /// Lifecycle state — `current` snapshot + replaying `stream`
    /// (StateFlow semantics per `ObservableState.swift`).
    var state: any ObservableState<AssistantState> { get }

    /// Set the session up: resolve the live dashboard config, build the
    /// runtime, register sleep phrases, land Dormant (or wake immediately
    /// when `config.startActive`). Idempotent while the session is alive;
    /// throws `AssistantError.sessionEnded` after `stop()`.
    func start() async throws

    /// Open the realtime connection: Activating → Active, wake chime,
    /// automatic greeting per `config.greeting`, `onWake` hook. No-op if
    /// already up; throws `notReady` before `start()`, `sessionEnded`
    /// after `stop()`, `networkError` if the connect fails (state returns
    /// to Dormant — retryable).
    func wake() async throws

    /// Close the realtime connection but keep the session: Sleeping →
    /// Dormant, `AssistantEvent.wentDormant`, `onSleep` hook. No-op when
    /// already down; throws `sessionEnded` after `stop()`.
    func sleep() async throws

    /// Tear the session down for good: close the connection, cancel the
    /// audio pump + inflight tools, release the singleton slot, emit
    /// `AssistantEvent.sessionEnded(reason: .user)`. Idempotent.
    func stop() async

    /// Speak `text` through the glasses (out-of-band `say` — does not
    /// join the conversation history). Requires Active.
    func say(_ text: String) async throws

    /// Generate a fresh greeting out-of-band from the persistent-memory
    /// preamble + `prompt` (nil = the core default directive). Requires
    /// Active. `wake()` calls this automatically per `config.greeting`.
    func greet(_ prompt: String?) async throws

    /// Include an image (file URI or https URL) in the conversation for
    /// the model's next turn, with an optional accompanying prompt.
    func includeImage(uri: String, prompt: String?) async throws

    /// Live-swap the reasoning effort (reasoning-capable models only —
    /// the core no-ops it elsewhere).
    func setReasoningEffort(_ effort: ReasoningEffort) async throws

    /// Live-swap the voice mid-session.
    func setVoice(_ voice: String) async throws

    /// Live-swap the model. The core re-derives reasoning capability.
    func setModel(_ model: String) async throws

    /// Replace the system instructions mid-session.
    func updateInstructions(_ instructions: String) async throws

    /// Barge-in: stop the assistant mid-utterance (cancels the active
    /// response + flushes queued audio).
    func cancelSpeak() async

    /// Snapshot of the newest `limit` buffered turns (oldest first).
    func conversationHistory(limit: Int) -> [Turn]

    /// Clear the local history buffer (the live provider conversation is
    /// unaffected until the next reconnect replay).
    func clearHistory()

    /// Append a synthetic turn to the local buffer.
    func appendHistory(_ turn: Turn)

    /// Replace the local buffer wholesale (also completes any in-flight
    /// compaction core-side).
    func replaceHistory(_ turns: [Turn])
}

public extension AssistantSession {
    /// `conversationHistory()` defaults to the newest 100 turns.
    func conversationHistory() -> [Turn] { conversationHistory(limit: 100) }

    /// `greet()` with the core default directive.
    func greet() async throws { try await greet(nil) }
}

/// Session lifecycle states — the canonical 8-state vocabulary, decided by
/// the core's transition table (realtime/lifecycle.rs; identical on
/// Android). Transitions:
///
///     idle ──start()──▶ dormant ──wake()──▶ activating ──▶ active
///       ▲                  ▲                    │(fail)       │
///       │                  └────────────────────┘             │
///       │                  dormant ◀── sleeping ◀──sleep()────┘
///       │                                        active ⇄ reconnecting
///       └── any ──stop()──▶ stopping ──▶ stopped
public enum AssistantState: Sendable, Equatable {

    /// Created; `start()` not yet called.
    case idle

    /// Set up and ready to wake; no open connection.
    case dormant

    /// `wake()` in progress — connecting to the provider.
    case activating

    /// Connection open; the assistant is in conversation.
    case active

    /// Transparent mid-session reconnect (provider ceiling, proactive
    /// cadence, or network drop). Customer code normally never sees it —
    /// `AssistantEvent.reconnected` fires for observability.
    case reconnecting

    /// `sleep()` in progress — closing the connection.
    case sleeping

    /// `stop()` in progress — full teardown.
    case stopping

    /// Ended for good; create a new session.
    case stopped
}
