import Foundation

// Data types consumed by `AssistantClient.createSession(config:)` (raw form)
// and produced by the `AssistantConfigBuilder` trailing-closure sugar. The
// customer-can-skip-it lock is preserved by keeping these plain values —
// a customer programmatically loading tools from config can always build an
// `AssistantConfig` directly without the builder.
//
// Mirrors `android-library/.../assistant/AssistantConfig.kt` (field-for-field;
// Swift naming + `TimeInterval` instead of Kotlin `Duration`).

/// Full configuration for an assistant session. Immutable; constructed
/// directly (raw form) or by `AssistantConfigBuilder` (sugar form).
public struct AssistantConfig: Sendable {

    /// Which provider drives the session (OpenAI Realtime via the managed
    /// gateway, or Mock for tests).
    public let provider: AssistantProvider

    /// System prompt for the model. Customer owns the full text; the
    /// library appends only its own operational notes (device-info tool
    /// note, glasses-state standing line) — all core-owned.
    public let instructions: String

    /// Tools the model may call. Empty is legal (voice-only chat).
    public let tools: [ToolDefinition]

    /// Skip Dormant on `start()` — open the connection immediately, as if
    /// `wake()` was called. Default false (session starts Dormant and waits
    /// for a wake).
    public let startActive: Bool

    /// Fire-and-forget hook run after each wake completes (state already
    /// Active). Errors emit `AssistantEvent.error(kind: "wake_hook")` and do
    /// NOT roll the state back.
    public let onWake: (@Sendable (any AssistantSession) async throws -> Void)?

    /// Fire-and-forget hook run after each sleep completes (state already
    /// Dormant — `say()` will throw; cleanup only).
    public let onSleep: (@Sendable (any AssistantSession) async throws -> Void)?

    /// Auto-sleep after this much user+assistant silence, or nil for none.
    /// Tracked in the core from the realtime frames (speech, active
    /// response, playback) — `RealtimeEvent.silenceTimeout` → `sleep()`.
    public let silenceTimeout: TimeInterval?

    /// Utterances that put the assistant to sleep ("goodbye", "that's all").
    /// Registered as voice handlers that stay active across wake/sleep cycles.
    public let sleepPhrases: [String]

    /// Inject the model-driven `end_conversation` tool (default ON) so the
    /// model itself can end the conversation on clear intent ("bye",
    /// "I'm done"). Tool name + description are core-owned.
    public let endOnIntent: Bool

    /// Max turns held in the local history buffer replayed on reconnect.
    /// Default 100 (~45 min of conversation; the gpt-realtime-2 quality
    /// cliff sits around 100–150 turns). Must be > 0.
    public let historyCap: Int

    /// What happens as the buffer approaches `historyCap`. Default
    /// `.auto` — the SDK summarizes the oldest ~50% via the compaction
    /// model and replaces them with one summary turn.
    public let historyCompaction: HistoryCompaction

    /// Chat model used by `.auto` compaction (the "memory model", NOT a
    /// Realtime model). nil = the project's dashboard setting, falling back
    /// to the core default (gpt-4o-mini). Code-set wins over dashboard.
    public let compactionModel: String?

    /// Dashboard "smart"/"basic" within-session memory mode, filled by the
    /// live-config overlay at session start; nil otherwise. Only `.auto`
    /// compaction consults it.
    public let withinSessionMemory: String?

    /// Cross-session persistent memory (v0). When true the SDK loads the
    /// stored profile at session start, injects it as context, extracts
    /// durable signal at session end, and merges it back. Gateway-mode
    /// feature (the profile lives on the Extentos backend) unless a custom
    /// `memoryStore` is provided.
    public let persistentMemory: Bool

    /// Your app's id for the signed-in user. nil → memory follows the
    /// device (attested device id); non-nil → memory follows this user
    /// across devices/reinstalls. Always project-scoped.
    public let memoryUserId: String?

    /// Custom profile storage (replaces the Extentos backend store). Lets
    /// BYOK-style apps keep persistent memory fully on their own
    /// infrastructure.
    public let memoryStore: (any MemoryStore)?

    /// What the assistant says when woken. Default `.default` — the
    /// core-owned directive + the user's memory context.
    public let greeting: Greeting

    /// Play the wake-confirmation chime at the start of each wake (fills
    /// the connect-wait silence). Default true.
    public let wakeSoundEnabled: Bool

    /// Register the built-in `get_device_info` tool (default ON) so the
    /// model can pull device capabilities/state on demand.
    public let includeDeviceInfoTool: Bool

    /// Override the core's device-info system-prompt note. nil → the
    /// built-in note; "" → omit entirely.
    public let deviceInfoNote: String?

    public init(
        provider: AssistantProvider,
        instructions: String = "",
        tools: [ToolDefinition] = [],
        startActive: Bool = false,
        onWake: (@Sendable (any AssistantSession) async throws -> Void)? = nil,
        onSleep: (@Sendable (any AssistantSession) async throws -> Void)? = nil,
        silenceTimeout: TimeInterval? = nil,
        sleepPhrases: [String] = [],
        endOnIntent: Bool = true,
        historyCap: Int = 100,
        historyCompaction: HistoryCompaction = .auto,
        compactionModel: String? = nil,
        withinSessionMemory: String? = nil,
        persistentMemory: Bool = false,
        memoryUserId: String? = nil,
        memoryStore: (any MemoryStore)? = nil,
        greeting: Greeting = .default,
        wakeSoundEnabled: Bool = true,
        includeDeviceInfoTool: Bool = true,
        deviceInfoNote: String? = nil
    ) {
        precondition(
            silenceTimeout.map { $0 > 0 } ?? true,
            "silenceTimeout must be strictly positive; omit or pass nil for no auto-sleep."
        )
        precondition(
            historyCap > 0,
            "historyCap must be > 0. Use HistoryCompaction.none if you want no buffer-based replay at all."
        )
        self.provider = provider
        self.instructions = instructions
        self.tools = tools
        self.startActive = startActive
        self.onWake = onWake
        self.onSleep = onSleep
        self.silenceTimeout = silenceTimeout
        self.sleepPhrases = sleepPhrases
        self.endOnIntent = endOnIntent
        self.historyCap = historyCap
        self.historyCompaction = historyCompaction
        self.compactionModel = compactionModel
        self.withinSessionMemory = withinSessionMemory
        self.persistentMemory = persistentMemory
        self.memoryUserId = memoryUserId
        self.memoryStore = memoryStore
        self.greeting = greeting
        self.wakeSoundEnabled = wakeSoundEnabled
        self.includeDeviceInfoTool = includeDeviceInfoTool
        self.deviceInfoNote = deviceInfoNote
    }
}

/// What the SDK does when the local history buffer approaches
/// `AssistantConfig.historyCap`. Mirrors Kotlin's `HistoryCompaction`.
public enum HistoryCompaction: Sendable {

    /// Default. The SDK summarizes the oldest ~50% of turns via the
    /// compaction model (through the managed gateway) and replaces them
    /// with a single summary turn — conversations keep working as long as
    /// the user wants to talk.
    case auto

    /// Drop the oldest turns silently once the cap is reached. No network,
    /// no summary — old context is simply forgotten.
    case dropOldest

    /// Your own compactor: receives the turns to compress, returns the
    /// full replacement history. A thrown error / failure leaves the
    /// buffer unchanged and retries on the next trigger.
    case custom(compact: @Sendable ([Turn]) async throws -> [Turn])

    /// No compaction. The buffer grows to `historyCap` and then behaves
    /// like `.dropOldest` at the hard cap.
    case none
}

/// What the assistant says when woken. Mirrors Kotlin's `Greeting`.
public enum Greeting: Sendable {

    /// Greet using `Greeting.defaultDirective` + the user's memory context.
    case `default`

    /// Greet using your own directive + the memory context. Extend the
    /// default with `.custom(Greeting.defaultDirective + " …")`; pass ""
    /// to greet from the memory content alone.
    case custom(directive: String)

    /// No automatic greeting — the developer greets manually via
    /// `session.greet(_:)` or not at all.
    case off

    /// The default greeting directive — core-owned model-facing English
    /// (realtime/state.rs). Exposed so apps can build on it.
    public static var defaultDirective: String { defaultGreetingDirective() }
}

/// Custom persistent-memory storage — plug your own backend in place of
/// the Extentos store. Both methods are best-effort: return nil / ignore
/// failures and the SDK degrades to "no memory this session".
public protocol MemoryStore: Sendable {

    /// Load the stored profile JSON for `userId` (the value of
    /// `AssistantConfig.memoryUserId`, or nil), or nil if none exists.
    func load(userId: String?) async -> String?

    /// Persist the merged profile JSON for `userId`.
    func save(userId: String?, profileJson: String) async
}

/// A single tool the assistant can call. The runtime translates each one
/// into the provider's native tool shape and routes tool-call events to
/// `body` by `name`.
///
/// ## Cross-platform asymmetry (Q3 lock)
/// Kotlin infers the JSON Schema from a @Serializable type; Swift has no
/// equivalent without macros, so the typed `tool<Args>(...)` overload takes
/// an EXPLICIT `schema` (see `Tool.swift`). The schema sent to the provider
/// is identical regardless of platform.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let schema: JSONValue?
    public let blocking: Bool
    public let body: @Sendable (JSONValue) async throws -> ToolResult

    public init(
        name: String,
        description: String,
        schema: JSONValue? = nil,
        blocking: Bool = false,
        body: @escaping @Sendable (JSONValue) async throws -> ToolResult
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.blocking = blocking
        self.body = body
    }
}

/// Result of a tool invocation, surfaced back to the model as the
/// `function_call_output` payload. Use short, factual strings — the model
/// reads this and weaves it into its next utterance. For structured data,
/// emit JSON as a string.
public enum ToolResult: Sendable {
    case ok(String)
    case err(String)
}

/// Receiver for the `AssistantClient.start(provider:_:)` trailing closure.
/// Plain builder — no library-side runtime interpretation ("builder block",
/// NOT a pre-pivot DSL; the customer can always construct `AssistantConfig`
/// directly).
public final class AssistantConfigBuilder: @unchecked Sendable {

    /// System prompt for the model. Last assignment wins.
    public var instructions: String = ""

    /// Tools registered so far — `Tool.swift`'s `tool(...)` extensions
    /// append here; direct mutation is fine too.
    public var tools: [ToolDefinition] = []

    /// Skip Dormant on start — connect immediately.
    public var startActive: Bool = false

    /// Inject the model-driven `end_conversation` tool (default on).
    public var endOnIntent: Bool = true

    /// Max local-history turns replayed on reconnect (> 0).
    public var historyCap: Int = 100

    /// Compaction policy once the buffer approaches `historyCap`.
    public var historyCompaction: HistoryCompaction = .auto

    /// Chat model for `.auto` compaction; nil = dashboard, then core default.
    public var compactionModel: String? = nil

    /// Cross-session persistent memory (v0).
    public var persistentMemory: Bool = false

    /// App-side user id for memory keying; nil = device-keyed.
    public var memoryUserId: String? = nil

    /// Custom profile storage in place of the Extentos backend store.
    public var memoryStore: (any MemoryStore)? = nil

    /// Wake greeting. Default: the core directive + memory context.
    public var greeting: Greeting = .default

    /// Wake-confirmation chime on each wake.
    public var wakeSoundEnabled: Bool = true

    private var onWakeHook: (@Sendable (any AssistantSession) async throws -> Void)?
    private var onSleepHook: (@Sendable (any AssistantSession) async throws -> Void)?
    private var silenceTimeoutValue: TimeInterval?
    private var sleepPhraseList: [String] = []

    internal init() {}

    /// Hook run after each wake completes (fire-and-forget; errors emit
    /// `AssistantEvent.error`, never roll back state).
    public func onWake(_ block: (@Sendable (any AssistantSession) async throws -> Void)?) {
        onWakeHook = block
    }

    /// Hook run after each sleep completes (state already Dormant —
    /// cleanup only; `say()` throws there).
    public func onSleep(_ block: (@Sendable (any AssistantSession) async throws -> Void)?) {
        onSleepHook = block
    }

    /// Auto-sleep after this much silence. Must be strictly positive.
    public func sleepAfterSilence(_ duration: TimeInterval) {
        silenceTimeoutValue = duration
    }

    /// Add an utterance that puts the assistant to sleep.
    public func sleepOnPhrase(_ phrase: String) {
        sleepPhraseList.append(phrase)
    }

    internal func build(provider: AssistantProvider) -> AssistantConfig {
        AssistantConfig(
            provider: provider,
            instructions: instructions,
            tools: tools,
            startActive: startActive,
            onWake: onWakeHook,
            onSleep: onSleepHook,
            silenceTimeout: silenceTimeoutValue,
            sleepPhrases: sleepPhraseList,
            endOnIntent: endOnIntent,
            historyCap: historyCap,
            historyCompaction: historyCompaction,
            compactionModel: compactionModel,
            persistentMemory: persistentMemory,
            memoryUserId: memoryUserId,
            memoryStore: memoryStore,
            greeting: greeting,
            wakeSoundEnabled: wakeSoundEnabled
        )
    }
}

// ── Errors ───────────────────────────────────────────────────────────

/// Open-time and lifecycle failures from the assistant runtime. Swift enums
/// conform to `Error`, so this doubles as the kind enum and the throwable
/// type (vs Kotlin's `AssistantException` wrapper).
public enum AssistantError: Error, Sendable {

    /// The managed gateway isn't reachable from this build context (dev
    /// builds reach it through the simulator — connect to the sim;
    /// beta/production builds attest automatically).
    case noApiKey

    /// A session is already active (singleton-active). Stop the current
    /// session before starting a new one.
    case alreadyActive

    /// The session has ended (`stopped`/`stopping`); create a new one via
    /// `createSession(config:)`.
    case sessionEnded

    /// The operation needs `start()` first (e.g. `wake()` on an Idle
    /// session).
    case notReady

    /// WebSocket open or handshake failed. Initial connection does NOT
    /// auto-retry — mid-session drops go through the reconnection state
    /// machine instead.
    case networkError(cause: any Error & Sendable)

    /// Provider returned a structured error event; message is the
    /// provider's text, treat as opaque.
    case providerError(code: String, message: String)
}
