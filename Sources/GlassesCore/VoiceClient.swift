import Foundation

// Convenience surface over `glasses.audio.transcriptions()` that ALSO
// announces "this app responds to phrase X" to the simulator + the
// host-app connection page. Customers who want raw control of STT
// can still subscribe to `glasses.audio.transcriptions()` directly —
// the voice client is sugar, not a runtime layer.
//
// Two registration forms:
//   - `onPhrase(phrase, label?, stops?) { handler }` — the library
//     matches the phrase (case-insensitive substring on final
//     transcripts) and dispatches.
//   - `registerHint(phrase, label?, stops?)` — the customer matches
//     themselves (e.g. regex, stateful guards) but still wants the UI
//     affordance to show up.
//
// `stops` is BOTH a UI affordance AND a runtime cancellation
// primitive:
//   - UI: simulator renders nested STOP rows under the parent VOICE
//     card; the host-app connection page shows them indented italic
//     under "Say to me". Gated by the parent's active state.
//   - Runtime: while a handler is executing, the library races it
//     against a transcription watcher; the first FINAL transcript
//     whose text contains any stop phrase (case-insensitive substring)
//     cancels the handler's Task. Customer's `try/finally` (or Swift
//     `defer`) runs normally — cancellation is plain structured
//     concurrency. For cleanup that itself needs to suspend, wrap it
//     in `Task.detached { … }` or `withTaskCancellationHandler` so it
//     survives the cancel.
//
//   glasses.voice.onPhrase(
//       phrase: "play cat video",
//       stops: ["stop the video"]
//   ) {
//       await catPlayer.play()   // cancelled on "stop the video"
//   }
//
// Mirrors `android-library/.../core/VoiceClient.kt`. Keep types and
// wire shape in lockstep — the simulator UI is shared across
// platforms.

public protocol VoiceClient: Sendable {
    /// Snapshot of every currently-registered voice hint. Updates when
    /// a hint is registered, cancelled, or becomes/stops being active
    /// (during handler execution).
    ///
    /// The simulator subscribes via the `app_voice_hints` frame to
    /// render click-to-fire chips; the connection page subscribes via
    /// `ExtentosUiState.voiceHints` to render "Say to me".
    var hints: any ObservableState<[VoiceHint]> { get }

    /// Per-hint stats keyed by `VoiceHint.id`. Updates each time a
    /// hint matches a transcript OR is explicitly bumped via
    /// `reportFired(id:)`.
    var stats: any ObservableState<[String: VoiceHintStats]> { get }

    /// Register a phrase + handler. The library subscribes to
    /// `audio.transcriptions()` once across all `onPhrase`
    /// registrations and dispatches by case-insensitive substring
    /// match on the final transcript.
    ///
    /// While the handler is running, the hint's `isActive` is true.
    /// `stops` (case-insensitive substring on final transcripts) cancel
    /// the handler's Task — customer keeps its own `try/finally`/
    /// `defer` for cleanup; the library only races the cancellation.
    /// Empty stops means the handler runs to completion or natural
    /// outer cancellation.
    ///
    /// Returns a registration handle whose `cancel()` removes the
    /// hint.
    func onPhrase(
        phrase: String,
        label: String?,
        stops: [String],
        handler: @escaping @Sendable () async -> Void
    ) -> VoiceRegistration

    /// Announce a phrase to the UI surfaces WITHOUT taking over the
    /// matching path. The customer's own transcription collector or
    /// capture-stop logic does the work; the hint is purely
    /// informational so the simulator + connection page can render the
    /// affordance. `stats` still updates if the customer calls
    /// `reportFired(id:)`; otherwise `firedCount` stays at 0.
    func registerHint(
        phrase: String,
        label: String?,
        stops: [String]
    ) -> VoiceRegistration

    /// Manually increment a hint's fired-count + last-fired timestamp.
    /// Useful for hints registered via `registerHint` whose matching
    /// lives in customer code. No-op for unknown ids (registration was
    /// already cancelled).
    func reportFired(id: String)
}

public extension VoiceClient {
    /// Convenience `onPhrase` with defaulted `label`/`stops`. Mirrors
    /// Kotlin's defaulted parameters.
    func onPhrase(
        phrase: String,
        handler: @escaping @Sendable () async -> Void
    ) -> VoiceRegistration {
        onPhrase(phrase: phrase, label: nil, stops: [], handler: handler)
    }

    /// Convenience `registerHint` with defaulted `label`/`stops`.
    func registerHint(phrase: String) -> VoiceRegistration {
        registerHint(phrase: phrase, label: nil, stops: [])
    }
}

// `VoiceHint` and `VoiceHintStats` were migrated to the Rust core
// (extentos-core) in shared-core Phase 1. They are now the uniffi-generated
// types in module `GlassesCore` (see Generated/extentos_core.swift) — same
// fields, same module, so customer `import`s and call sites are unchanged.
// `Conformances.swift` restores `Sendable` + `VoiceHint: Identifiable` (uniffi
// drops these); `VoiceTransportBridge.buildFrame` reads them by their
// unchanged accessors (`isActive`, `hasHandler`, `firedCount`, `lastFiredAtMs`).

/// Handle returned by `onPhrase` / `registerHint`. Idempotent
/// `cancel()` removes the registration. The protocol is intentionally
/// minimal — no `id` on the surface (the customer can hold the
/// returned handle and ignore identity).
public protocol VoiceRegistration: Sendable {
    func cancel()
}
