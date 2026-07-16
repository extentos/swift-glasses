// API-compatibility shims for the data types migrated to the Rust core
// (extentos-core). The migrated types themselves are the uniffi-generated
// bindings in Generated/extentos_core.swift, compiled into this module so the
// customer-facing names (`Resolution`, `ConnectError`, …) and `import
// GlassesCore` are unchanged. uniffi-generated enums carry no custom members
// and no `Error` conformance, so the small bits of hand-written API surface
// they would otherwise lose are restored here. (The `Sendable` / `Error`
// conformances themselves live in Conformances.swift.)

// `ExtentosEnvironment.wireValue` — public API, used by the telemetry envelope.
public extension ExtentosEnvironment {
    /// Lowercase wire form sent on every telemetry event.
    var wireValue: String {
        switch self {
        case .development: return "development"
        case .beta: return "beta"
        case .production: return "production"
        }
    }
}

// § 3b error bridging: a Rust core cannot hold a Swift `Error`, so a native
// transport failure is converted to a structured `code` + `message` at the
// catch site. The original error object is not retained on the public type —
// `message` carries its description; richer per-error `code`s are a follow-up.
public extension ConnectError {
    /// Build a `transportFailure` from a caught native error.
    static func transportFailure(wrapping error: Error) -> ConnectError {
        .transportFailure(code: "transport_failure", message: String(describing: error))
    }
}

// ── Phase 2.0 transport types ────────────────────────────────────────────────

// `wireValue` — the wire form of the transport-selection enums. The
// hand-written iOS enums were `String`-RawRepresentable, so the wire form was
// `.rawValue`; the uniffi-generated enums carry no raw type, so the exact wire
// strings are restored here as computed properties. `TranscriptSource` /
// `TransportSelectionSource` are snake_case; `TransportChosen` keeps the
// PascalCase labels the telemetry event-log schema expects.
public extension TranscriptSource {
    var wireValue: String {
        switch self {
        case .appleStt: return "apple_stt"
        case .googleStt: return "google_stt"
        case .webSpeechApi: return "web_speech_api"
        case .whisperBrowser: return "whisper_browser"
        }
    }
}

public extension TransportChosen {
    var wireValue: String {
        switch self {
        case .realMeta: return "RealMeta"
        case .browserSim: return "BrowserSim"
        case .localSim: return "LocalSim"
        }
    }
}

public extension TransportSelectionSource {
    var wireValue: String {
        switch self {
        case .buildConfig: return "build_config"
        case .envVar: return "env_var"
        case .bondedDevices: return "bonded_devices"
        case .fallbackDefault: return "fallback_default"
        case .explicitConfig: return "explicit_config"
        case .pairing: return "pairing"
        }
    }
}

// § 3b error bridging for the capture / audio / transport errors — same shape
// as `ConnectError.transportFailure(wrapping:)` above. A Rust core cannot hold
// a Swift `Error`, so a caught native error is converted to a structured
// `code` + `message` at the catch site. `code` is a single stable
// `"platform_error"` tag (richer per-error codes are a follow-up); `message`
// carries the caught error's description. The original error object is not
// retained on the public type.
public extension CaptureError {
    /// Build a `platformError` from a caught native error.
    static func platformError(wrapping error: Error) -> CaptureError {
        .platformError(code: "platform_error", message: String(describing: error))
    }
}

public extension AudioError {
    /// Build a `platformError` from a caught native error.
    static func platformError(wrapping error: Error) -> AudioError {
        .platformError(code: "platform_error", message: String(describing: error))
    }
}

public extension TransportError {
    /// Build a `platformError` from a caught native error.
    static func platformError(wrapping error: Error) -> TransportError {
        .platformError(code: "platform_error", message: String(describing: error))
    }
}

// Accessors the hand-written enums exposed as members. uniffi generates each
// enum variant independently, so the shared accessors are reattached here.
public extension ActiveState {
    /// The connected device, common to every `ActiveState` variant.
    var device: DeviceInfo {
        switch self {
        case .connected(let d, _): return d
        case .sessionActive(let d, _): return d
        case .streamActive(let d, _): return d
        }
    }
}

public extension GlassesState {
    /// The `ActiveState` payload when this is `.active`, otherwise `nil`.
    var active: ActiveState? {
        if case let .active(inner) = self { return inner } else { return nil }
    }
}
