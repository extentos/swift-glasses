import Foundation

// Surfaces the on-device event log to the host app. Post pure-SDK pivot
// the client only relays transport-level events (ToggleChanged, Log,
// UnrecognizedUtterance, CoexistenceWarning); spec-runtime variants are
// gone — see shared-context/ios-pure-sdk-pivot-handoff.md.
//
// Mirrors `android-library/.../core/RuntimeClient.kt` + `RuntimeEvent.kt`
// (Android keeps the protocol and the event enum in separate files; iOS
// keeps them collocated in this single file per the existing layout).

public protocol RuntimeClient: Sendable {
    var events: AsyncStream<RuntimeEvent> { get }

    func snapshotEvents() async -> [RuntimeEvent]
}

public enum RuntimeEvent: Sendable {
    /// User-driven toggle change. `source` distinguishes UI flips from
    /// future automation paths (kept around so consumers can filter).
    case toggleChanged(key: String, oldValue: JSONValue, newValue: JSONValue, source: ToggleSource)
    /// Audio/video coexistence rule blocked an op. `blocked` names the
    /// op (e.g. `capture_video`, `transcriptions`); `reason` is a stable
    /// snake_case tag for filtering.
    case coexistenceWarning(blocked: String, reason: String)
    /// Diagnostic log line surfaced through the public event stream.
    /// `payload` is optional structured detail for filtered subscribers.
    case log(level: LogLevel, message: String, payload: JSONValue?)
    /// Voice-engine yielded a transcript that didn't match any host
    /// expectation. Useful for "what did the mic actually hear?" debug
    /// surfaces. Post pure-SDK pivot the library no longer matches
    /// triggers — emission is host-driven.
    case unrecognizedUtterance(rawTranscript: String)

    /// Phase 4 — an assistant runtime lifecycle event. Wraps the
    /// `AssistantEvent` enum (sessionStarted / sessionEnded / userSpoke /
    /// assistantSpoke / toolCalled / toolResult / reconnected / error).
    /// Forwarded by `DefaultAssistantClient` (S1.M.4) to the shared
    /// `EventLogger` so it reaches `glasses.runtime.events`, the
    /// simulator's event-log panel, and `getEventLog()` MCP.
    ///
    /// Customer code subscribes via
    /// `for await event in glasses.runtime.events { if case .assistant(let a) = event ... }`
    /// for assistant-level observability.
    ///
    /// PII boundary differs from `.conversation`: assistant events DO
    /// carry verbatim transcripts in `AssistantEvent.userSpoke` /
    /// `.assistantSpoke`. The Phase 4 BYOK contract routes transcripts
    /// customer-device → openai.com directly without touching Extentos
    /// backend, so the platform-side PII boundary that Phase 3 enforced
    /// (cascaded path passed transcripts through Extentos backend)
    /// doesn't apply. Customer apps are responsible for their own data
    /// retention story per synthesis #14 (full-glass access).
    ///
    /// Mirrors Android `RuntimeEvent.Assistant` (`3ade958`).
    case assistant(AssistantEvent)
}

public enum ToggleSource: Sendable {
    case ui
    case voiceCommand
    case automationTrigger
}
