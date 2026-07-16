import Foundation

// ObservabilityClient — public surface for surfacing customer-side AI
// calls in the simulator event log.
//
// F-R3-11 (R3 dogfood): BYOK AI calls (Anthropic / OpenAI / Gemini /
// etc.) traverse api.<provider>.com directly from the customer's app
// and never cross the simulator's WebSocket relay. That makes them
// invisible to `getEventLog`, leaving an unexplained 1-3 second gap
// between `photo_result` and `speak` in every canonical voice-glasses
// flow. Diagnosing failures (auth, 5xx, timeouts) required pulling
// OSLog — a context-switch out of the simulator-driven debug surface.
//
// `glasses.observability.aiCall(label:) { block }` wraps a single
// provider call and emits two frames over the simulator transport:
//
//   { "type": "ai_call_start", "label": "<label>", "metadata": {...} }
//   { "type": "ai_call_end",   "label": "<label>", "duration_ms": N,
//                              "success": <Bool>, "error_class"?, "error_message"? }
//
// Both frames carry `type` prefixed with `ai_`, which the backend
// classifier maps to `layer: "ai"` — so they surface under
// `getEventLog(filter: "ai")` automatically with no backend changes.
//
// The wrapper is a no-op against transports that don't carry the
// simulator relay (RealMeta, LocalSim) — start/end frames just don't
// emit. The block's return value (or thrown error) passes through
// unchanged in every case.

public protocol ObservabilityClient: Sendable {

    /// Wrap a BYOK AI provider call so it appears in the simulator
    /// event log under the "ai" filter chip.
    ///
    /// - Parameters:
    ///   - label: Stable identifier for this call site, e.g.
    ///     "anthropic.describe" or "openai.gpt4v.vision". Surfaces
    ///     verbatim in the event log; pick a name that lets you
    ///     filter by call site later.
    ///   - metadata: Optional key-value pairs to attach to the start
    ///     frame (model name, prompt-size hint, etc.). Lives entirely
    ///     in the simulator event log on the dev's machine; never
    ///     sent to telemetry. Strings only — keep payloads short,
    ///     this is for at-a-glance debug context, not full logs.
    ///   - block: The async call to time + wrap. Return value passes
    ///     through unchanged. If `block` throws, the error re-throws
    ///     after the end frame is emitted (so the simulator records
    ///     the failure before propagation).
    /// - Returns: Whatever `block` returns.
    func aiCall<T: Sendable>(
        label: String,
        metadata: [String: String],
        block: @Sendable () async throws -> T
    ) async rethrows -> T
}

public extension ObservabilityClient {
    /// Convenience overload — `metadata` defaults to empty.
    func aiCall<T: Sendable>(
        label: String,
        block: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await aiCall(label: label, metadata: [:], block: block)
    }
}
