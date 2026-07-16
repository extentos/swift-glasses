import Foundation

// `assistant.*` event family.
//
// Wrapped by `RuntimeEvent.assistant` (see `RuntimeClient.swift`) so events
// flow through the existing `glasses.runtime.events` stream alongside
// transport + toggle events. The transport bridge forwards each event to
// BrowserSim's outbound JSON path so the simulator's event-log panel
// renders them.
//
// PII boundary: transcript fields carry the verbatim text for the
// customer's own app + their simulator. Extentos relays the audio/text in
// gateway mode but persists only aggregate metadata per the data-collection
// posture — never transcript content.
//
// Mirrors `android-library/.../assistant/AssistantEvent.kt`.

public enum AssistantEvent: Sendable {

    /// Session opened successfully.
    case sessionStarted(provider: String, model: String?, voice: String?)

    /// Session closed for good (terminal — vs `wentDormant`).
    case sessionEnded(reason: EndReason, message: String?)

    /// The session went Dormant after a sleep — "this active turn ended,
    /// can be re-woken". UI surfaces flip their "in conversation"
    /// indicators off. Distinct from the terminal `sessionEnded`.
    case wentDormant

    /// User finished an utterance. Transcript is the provider's STT result.
    case userSpoke(transcript: String)

    /// Model finished an utterance (output transcript).
    case assistantSpoke(transcript: String)

    /// Model decided to call a tool. Fires BEFORE the tool body runs.
    case toolCalled(name: String, args: JSONValue, callId: String)

    /// Tool body returned a result. Fires AFTER the body completes.
    case toolResult(callId: String, name: String, output: String, isError: Bool, durationMs: Int64)

    /// Transparent mid-session reconnect completed. Observability only.
    case reconnected(reason: ReconnectReason, downtimeMs: Int64)

    /// Provider or transport error. Non-fatal errors (will retry) emit
    /// this; fatal errors emit `sessionEnded(reason: .error, ...)` instead.
    case error(kind: String, message: String)

    /// Why the session ended (`sessionEnded.reason`).
    public enum EndReason: String, Sendable {
        /// Customer called `assistant.stop()` / `session.stop()`.
        case user
        /// Unrecoverable error (auth, malformed response, etc.).
        case error
        /// 60-minute provider ceiling hit and reconnect failed.
        case ceiling
    }

    /// Why a reconnect happened (`reconnected.reason`).
    ///
    /// Raw values match the event-registry schema enum byte-for-byte
    /// (`event-registry/runtime/assistant.reconnected.v1.schema.json`):
    /// all lowercase, no underscores — matches Android's
    /// `.name.lowercase()` serialization.
    public enum ReconnectReason: String, Sendable {
        /// Proactive cadence (5–10 min default).
        case proactiveCadence = "proactivecadence"
        /// Approaching the 60-minute provider ceiling.
        case ceilingApproach = "ceilingapproach"
        /// Network failure (`onFailure` / `receive()` threw).
        case networkDrop = "networkdrop"
    }
}
