import Foundation

// Post pure-SDK pivot: triggers/stop_conditions are gone — the connection
// page no longer surfaces them. Remaining shape: status (connection +
// auth + firmware/device + library version) plus the abstract
// capabilities chip-row plus the user-facing toggles list. Mirrors
// `android-library/.../core/UiState.kt`.

public struct ExtentosUiState: Sendable {
    public let connection: GlassesState
    public let auth: AuthStatus
    public let firmware: String?
    public let deviceName: String?
    public let capabilities: [CapabilityEntry]
    public let toggles: [ToggleEntry]
    /// Customer-registered voice hints surfaced under the "Say to me"
    /// section. Sourced from `glasses.voice.hints`; display-only on
    /// the connection page (the simulator panel handles
    /// click-to-fire). Mirrors Android's
    /// `ExtentosUiState.voiceHints`.
    public let voiceHints: [VoiceHint]
    public let libraryVersion: String

    public init(
        connection: GlassesState,
        auth: AuthStatus,
        firmware: String?,
        deviceName: String?,
        capabilities: [CapabilityEntry] = [],
        toggles: [ToggleEntry] = [],
        voiceHints: [VoiceHint] = [],
        libraryVersion: String
    ) {
        self.connection = connection
        self.auth = auth
        self.firmware = firmware
        self.deviceName = deviceName
        self.capabilities = capabilities
        self.toggles = toggles
        self.voiceHints = voiceHints
        self.libraryVersion = libraryVersion
    }
}

public struct CapabilityEntry: Sendable, Identifiable {
    public let id: UUID
    public let kind: CapabilityKind
    public let label: String
    public let icon: String
    /// Whether this declared capability is live on the connected glasses —
    /// Active renders bright; Unavailable (declared but the device can't,
    /// e.g. Display on a non-display Ray-Ban) and Pending (still
    /// connecting) render dimmed. Mirrors Android.
    public let availability: CapabilityAvailability

    public init(
        id: UUID = UUID(),
        kind: CapabilityKind,
        label: String,
        icon: String,
        availability: CapabilityAvailability = .active
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.icon = icon
        self.availability = availability
    }
}

/// Per-device live state of a declared capability tile.
public enum CapabilityAvailability: Sendable {
    case active
    case unavailable
    case pending
}

public enum CapabilityKind: Sendable {
    case camera
    case microphone
    case speaker
    case location
    case notifications
    case display
    case other(String)
}

public struct ToggleEntry: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?
    public let value: Bool
    public let icon: String
    /// How to translate the displayed boolean back to a toggle-store
    /// write. `.bool`: write `.bool(newValue)`. `.listeningModeEnum`:
    /// write `.string("always_on")` for ON, `.string("off")` for OFF
    /// — the four-valued underlying enum is collapsed to a binary
    /// user-facing switch. The connection page UI consults this to
    /// dispatch the right write payload when the user flips the
    /// switch.
    public let kind: ToggleEntryKind
    public init(
        id: String,
        label: String,
        description: String?,
        value: Bool,
        icon: String,
        kind: ToggleEntryKind = .bool
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.value = value
        self.icon = icon
        self.kind = kind
    }
}

public enum ToggleEntryKind: Sendable {
    case bool
    case listeningModeEnum
}

// `AuthStatus` is the auth slice of `ExtentosUiState`. It is not a transport
// type and does not migrate to extentos-core; Phase 2.0's decision 5 flagged
// it for removal as an unused stray, but verification against source found
// `ExtentosUiState.auth` consumes it — so it stays native here, alongside its
// only consumer (it previously lived in the now-deleted GlassesState.swift).
public enum AuthStatus: Sendable {
    case authorized
    case required
    case error(underlying: any Error & Sendable)
}
