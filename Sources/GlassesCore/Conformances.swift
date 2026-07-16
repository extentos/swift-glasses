// Companion to the uniffi-generated bindings (Generated/extentos_core.swift).
//
// uniffi 0.28 emits the migrated types as Equatable/Hashable but not Sendable,
// and emits `ConnectError` as a plain enum. The Extentos public API needs the
// original conformances back: every migrated enum was declared `Sendable`, and
// `ConnectError` is the `Failure` of `ExtentosResult`, whose generic constraint
// is `Error & Sendable`.
//
// `Sendable` is declared `@unchecked`: Swift requires a *checked* `Sendable`
// conformance to sit in the same source file as the type, and the generated
// file is overwritten by the build script. The migrated types are genuine
// value types whose stored data is all `Sendable`, so `@unchecked` is sound.

extension Resolution: @unchecked Sendable {}
extension PhotoFormat: @unchecked Sendable {}
extension AudioQuality: @unchecked Sendable {}
extension EarconSound: @unchecked Sendable {}
extension ThermalSeverity: @unchecked Sendable {}
extension SessionPhase: @unchecked Sendable {}
extension SessionExpireReason: @unchecked Sendable {}
extension ExtentosEnvironment: @unchecked Sendable {}
extension EnvironmentClassification: @unchecked Sendable {}
extension EnvironmentReconciliation: @unchecked Sendable {}
extension ConnectError: @unchecked Sendable {}
extension ConnectError: Error {}

// Phase 1 — `VoiceHint` / `VoiceHintStats` migrated to extentos-core. uniffi
// emits them `Equatable`/`Hashable`; restore the conformances the hand-written
// iOS types carried: `Sendable` on both (the `VoiceClient` API surfaces them
// through `ObservableState`, whose `Element` is `Sendable`) and `Identifiable`
// on `VoiceHint` (its `id` already satisfies the requirement). Both are pure
// value types with all-`Sendable` storage, so `@unchecked` is sound.
extension VoiceHint: @unchecked Sendable {}
extension VoiceHint: Identifiable {}
extension VoiceHintStats: @unchecked Sendable {}

// Phase 2.0 — the transport data-type cluster + the four error enums migrated
// to extentos-core. uniffi emits them Equatable/Hashable but not Sendable; the
// hand-written iOS types were all `Sendable` (surfaced through `AsyncStream` /
// `ExtentosResult`, both Sendable-constrained), so the conformance is restored
// here. They are pure value types with all-`Sendable` storage, so `@unchecked`
// is sound. The four error enums also need `Error` back — uniffi emits them as
// plain enums, but they are the `Failure` of `ExtentosResult` (constraint
// `Error & Sendable`). `DeviceInfo` regains `Identifiable` (its `id` satisfies
// the requirement) the hand-written struct carried.
extension VideoFormat: @unchecked Sendable {}
extension Codec: @unchecked Sendable {}
extension DeviceType: @unchecked Sendable {}
extension TranscriptSource: @unchecked Sendable {}
extension TransportChosen: @unchecked Sendable {}
extension TransportSelectionSource: @unchecked Sendable {}
extension AudioRoute: @unchecked Sendable {}
extension AudioRouteChangeReason: @unchecked Sendable {}
extension CallState: @unchecked Sendable {}
extension AppLifecycleState: @unchecked Sendable {}
extension Photo: @unchecked Sendable {}
extension VideoClip: @unchecked Sendable {}
extension AudioRecording: @unchecked Sendable {}
extension DeviceInfo: @unchecked Sendable {}
extension DeviceInfo: Identifiable {}
extension StreamConfig: @unchecked Sendable {}
extension Transcript: @unchecked Sendable {}
extension HardwareAlert: @unchecked Sendable {}
extension ActiveState: @unchecked Sendable {}
extension DisconnectCause: @unchecked Sendable {}
extension GlassesState: @unchecked Sendable {}
extension SimulatorHint: @unchecked Sendable {}
extension TransportEvent: @unchecked Sendable {}
extension CaptureError: @unchecked Sendable {}
extension CaptureError: Error {}
extension AudioError: @unchecked Sendable {}
extension AudioError: Error {}
extension TransportError: @unchecked Sendable {}
extension TransportError: Error {}
extension ExtentosError: @unchecked Sendable {}
extension ExtentosError: Error {}
