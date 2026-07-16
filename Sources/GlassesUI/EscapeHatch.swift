import Foundation
import Combine
import SwiftUI
import GlassesCore

// Layer 3 escape hatch for callers who need the raw `ExtentosUiState`.
// Marked `@_spi(ExtentosEscapeHatch)` to require explicit opt-in imports —
// once a caller bypasses `ExtentosConnectionPage`, they're responsible for
// rendering future surfaces (battery row, new capability kinds, etc.) the
// library may add.
//
// Post pure-SDK pivot the builder no longer walks any spec. After the
// 1.1.30/31-pair voice client + dead-Capabilities-and-Toggles fix
// (`shared-context/2026-05-13-ios-voice-client-handoff.md`):
//   - Capabilities are the static hardware trio (Camera / Microphone /
//     Speaker) every Meta Ray-Ban device exposes.
//   - Toggles are rendered from the canonical 7-entry catalog with the
//     ToggleEntryKind hint so the connection-page write path dispatches
//     the correct wire value (bool vs listening_mode enum collapse).
//   - voiceHints flow from `glasses.voice.hints` and surface under
//     the "Say to me" section.
//
// Mirrors `android-library/.../ui/EscapeHatch.kt`.

@_spi(ExtentosEscapeHatch)
public func rememberExtentosState(_ glasses: any ExtentosGlasses) -> ExtentosUiState {
    UiStateBuilder.build(
        connection: glasses.connection.state.current,
        toggles: glasses.toggles.state.current,
        voiceHints: glasses.voice.hints.current,
        footprint: glasses.usedCapabilities,
        deviceCaps: glasses.capabilities
    )
}

/// `ObservableObject` form. Owns the subscription Tasks, republishes a
/// fresh `ExtentosUiState` whenever connection / toggles / voice change.
@_spi(ExtentosEscapeHatch)
@MainActor
public final class ExtentosStateModel: ObservableObject {
    @Published public private(set) var state: ExtentosUiState

    private let glasses: any ExtentosGlasses
    private var connectionTask: Task<Void, Never>?
    private var togglesTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?

    public init(glasses: any ExtentosGlasses) {
        self.glasses = glasses
        self.state = UiStateBuilder.build(
            connection: glasses.connection.state.current,
            toggles: glasses.toggles.state.current,
            voiceHints: glasses.voice.hints.current,
            footprint: glasses.usedCapabilities,
            deviceCaps: glasses.capabilities
        )
        let connectionStream = glasses.connection.state.stream
        let togglesStream = glasses.toggles.state.stream
        let voiceStream = glasses.voice.hints.stream
        connectionTask = Task { [weak self] in
            for await _ in connectionStream { self?.refresh() }
        }
        togglesTask = Task { [weak self] in
            for await _ in togglesStream { self?.refresh() }
        }
        voiceTask = Task { [weak self] in
            for await _ in voiceStream { self?.refresh() }
        }
    }

    deinit {
        connectionTask?.cancel()
        togglesTask?.cancel()
        voiceTask?.cancel()
    }

    private func refresh() {
        state = UiStateBuilder.build(
            connection: glasses.connection.state.current,
            toggles: glasses.toggles.state.current,
            voiceHints: glasses.voice.hints.current,
            footprint: glasses.usedCapabilities,
            deviceCaps: glasses.capabilities
        )
    }
}

// MARK: - Internal derivation — DECISIONS are core-owned (capability/mod.rs)
//
// Tiles (render order, declare-nothing-show-nothing, Pending/Active/
// Unavailable), the auth collapse, the toggle registry (ONE user-facing
// toggle post-pivot: Voice activation), and the listening-mode value
// collapse all come from the Rust core — the pre-hoist static capability
// floor (the phantom-Camera-tile footgun) and the 7-toggle catalog are
// gone, matching Android.

enum UiStateBuilder {
    static func build(
        connection: GlassesState,
        toggles: Toggles,
        voiceHints: [VoiceHint],
        footprint: [DeclaredCapability],
        deviceCaps: DeviceCapabilitySet
    ) -> ExtentosUiState {
        let device = activeDevice(connection)
        let connected: Bool
        if case .active = connection { connected = true } else { connected = false }
        return ExtentosUiState(
            connection: connection,
            auth: glassesStateRequiresAuth(state: connection) ? .required : .authorized,
            firmware: device?.firmwareVersion,
            deviceName: device?.modelName,
            capabilities: resolveCapabilityTiles(
                footprint: footprint,
                device: deviceCaps,
                connected: connected
            ).map { tile in
                CapabilityEntry(
                    kind: publicKind(tile.kind),
                    label: tile.label,
                    icon: tile.icon,
                    availability: publicAvailability(tile.state)
                )
            },
            toggles: renderToggles(state: toggles),
            voiceHints: voiceHints,
            libraryVersion: LibraryVersion.version
        )
    }

    private static func activeDevice(_ state: GlassesState) -> DeviceInfo? {
        if case .active(let active) = state { return active.device }
        return nil
    }

    private static func publicKind(_ kind: DeclaredCapability) -> CapabilityKind {
        switch kind {
        case .camera: .camera
        case .microphone: .microphone
        case .speaker: .speaker
        case .display: .display
        case .location: .location
        case .notifications: .notifications
        case .custom(let name): .other(name)
        }
    }

    private static func publicAvailability(_ state: CapabilityTileState) -> CapabilityAvailability {
        switch state {
        case .active: .active
        case .unavailable: .unavailable
        case .pending: .pending
        }
    }

    private static func renderToggles(state: Toggles) -> [ToggleEntry] {
        connectionPageToggles().map { def in
            ToggleEntry(
                id: def.key,
                label: def.label,
                description: def.description,
                value: toggleDisplayValue(
                    kind: def.kind,
                    rawJson: rawJsonText(state.values[def.key]),
                    defaultValue: def.defaultValue
                ),
                icon: def.icon,
                kind: def.kind == .listeningModeEnum ? .listeningModeEnum : .bool
            )
        }
    }

    /// The raw-JSON-text currency the core toggle grammar consumes.
    private static func rawJsonText(_ value: JSONValue?) -> String? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
