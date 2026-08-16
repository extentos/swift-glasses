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
    ///
    /// This is GENERATION finishing, not playback. The model streams audio
    /// faster than realtime, so this routinely fires seconds before the
    /// assistant stops talking — use `assistantAudioFinished` for anything that
    /// must wait until it has actually finished.
    case assistantSpoke(transcript: String)

    /// The assistant started talking — the rising edge of audible speech.
    ///
    /// Pairs with `assistantAudioFinished`, strictly alternating: exactly one
    /// finish follows each start. This is the pair a "Speaking" indicator or a
    /// screen transition belongs on, NOT `assistantSpoke`, which is the
    /// transcript and fires much earlier.
    case assistantAudioStarted

    /// The assistant stopped talking: its queued audio drained and the model
    /// finished the turn, including any tool round trip inside it. A turn that
    /// called a tool and then kept speaking finishes after the LAST segment, not
    /// at the tool call.
    ///
    /// Also fires immediately when playback is cut short by barge-in or
    /// `cancelSpeak()` — the audio did stop, and code waiting on this edge must
    /// not hang because the user interrupted.
    ///
    /// The drain is the SDK's estimate from the PCM it queued, not a report from
    /// the speaker. On glasses the phone is the player and the glasses are a
    /// Bluetooth sink, so the last ~100-200 ms of the hop is invisible to every
    /// layer of this SDK. Read it as "has finished, to within about a quarter
    /// second" — which is what a UI transition needs.
    case assistantAudioFinished

    /// Model decided to call a tool. Fires BEFORE the tool body runs.
    case toolCalled(name: String, args: JSONValue, callId: String)

    /// Tool body returned a result. Fires AFTER the body completes.
    case toolResult(callId: String, name: String, output: String, isError: Bool, durationMs: Int64)

    /// Transparent mid-session reconnect completed. Observability only.
    case reconnected(reason: ReconnectReason, downtimeMs: Int64)

    /// Provider or transport error. Non-fatal errors (will retry) emit
    /// this; fatal errors emit `sessionEnded(reason: .error, ...)` instead.
    case error(kind: String, message: String)

    /// `local-auto` resolved for THIS device. Fires once at session start,
    /// before any turn.
    ///
    /// The honesty half of Auto's contract: the developer chose to delegate
    /// the model choice, so they are told what it became and why — "I picked
    /// Auto and don't know whether my user's audio went to the cloud" is the
    /// one outcome the feature must never produce. It is also what lets a
    /// privacy-minded app enforce its own local-only policy without the SDK
    /// shipping a policy setting: read the resolution, decide your own
    /// consequence.
    ///
    /// `servedModelId` is always the CONCRETE model that will run — never
    /// `local-auto` — and is the id that must reach usage accounting, since
    /// an unknown id is stamped `needs_pricing` and silently goes unbilled.
    case autoModelResolved(
        servedModelId: String,
        isLocal: Bool,
        cloudReason: CloudFallbackReason?,
        downloadTarget: String?
    )

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
