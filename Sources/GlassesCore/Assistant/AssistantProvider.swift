import Foundation

// Provider abstraction for `glasses.assistant`. `openAI` is the MANAGED
// REALTIME provider, not an OpenAI-only switch: the resolved model id picks
// the vendor (`gpt-*` → OpenAI, `grok-*` → xAI Grok, `gemini-*` → Google
// Gemini Live — the core carries a protocol adapter per vendor), so
// switching vendors is a dashboard/model-id change, not a new provider
// case. `mock` is the deterministic in-process test provider. Provider
// config carries model-side knobs only (model name, voice, turn detection,
// reasoning effort); session behavior lives on `AssistantConfig`.
//
// Mirrors `android-library/.../assistant/AssistantProvider.kt`.

public enum AssistantProvider: Sendable {

    /// The managed realtime provider, through the Extentos gateway — the
    /// resolved model id picks the vendor (see the header note).
    ///
    /// `model` / `voice` are OPTIONAL: `nil` (the default) means "use the
    /// value configured for this project in the Extentos dashboard's Agent
    /// tab", falling back to the hard defaults (`AssistantProvider.defaultModel`
    /// / `.defaultVoice`) when the dashboard has none. A non-nil value set
    /// in code WINS over the dashboard — resolved once by the live-config
    /// overlay at session start.
    case openAI(
        model: String? = nil,
        voice: String? = nil,
        turnDetection: TurnDetection = .serverVad(),
        reasoningEffort: ReasoningEffort = .low
    )

    /// Deterministic in-process provider for unit tests + the MCP
    /// `injectAssistantUtterance(text:)` path. No network, no key.
    case mock(behavior: MockBehavior = .matchToolDescriptions)

    /// Hard fallback model used when neither code nor the dashboard sets
    /// one — core-owned (realtime/catalog.rs; matches the `realtime_model`
    /// DEFAULT in backend migration 0026).
    public static var defaultModel: String { assistantDefaultModel() }

    /// Hard fallback voice used when neither code nor the dashboard sets
    /// one — core-owned (matches `voice` DEFAULT in 0026).
    public static var defaultVoice: String { assistantDefaultVoice() }
}

/// How the model decides the user's turn is over.
public enum TurnDetection: Sendable {
    case serverVad(
        threshold: Double = 0.5,
        prefixPaddingMs: Int = 300,
        silenceDurationMs: Int = 500
    )
    case semanticVad
}

/// Reasoning effort for reasoning-capable Realtime models (gpt-realtime-2+).
/// Ignored by non-reasoning models — the core knows which is which
/// (realtime/catalog.rs) and only sends the knob where it applies.
///
/// Mirrors Kotlin's `ReasoningEffort`; `wireValue` is the OpenAI wire string.
public enum ReasoningEffort: String, Sendable, CaseIterable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    /// The OpenAI wire value (same as the case name today; kept explicit so
    /// a future wire rename can't silently change the public enum).
    var wireValue: String { rawValue }
}

/// Mock-provider behavior selector.
public enum MockBehavior: Sendable {
    /// Substring-match injected utterances against tool descriptions and
    /// invoke the best match (the `injectAssistantUtterance` dev loop).
    case matchToolDescriptions
}
