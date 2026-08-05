import Foundation

/// The runtime gates a customer's app and its connection page read and flip.
/// Mirrors Kotlin `ToggleClient` — per-key read and write, with the write
/// carrying WHY it happened.
///
/// The `source` is not decoration: it rides `RuntimeEvent.toggleChanged` into
/// telemetry as "ui" / "voice" / "automation". Before this shape landed, iOS
/// exposed only a whole-struct `update { }` transform with nowhere to put a
/// source, so the implementation hardcoded `.ui` — and every assistant- or
/// automation-driven toggle change on iOS was reported as a user tap.
public protocol ToggleClient: Sendable {

    /// The current toggle values — the same contents as Kotlin's
    /// `StateFlow<Map<String, JSONValue>>`.
    var state: any ObservableState<Toggles> { get }

    /// The value for `key`, or nil if it was never set.
    func get(key: String) -> JSONValue?

    /// Set `key`, recording what caused the change. An assistant tool or an
    /// automation must pass its own source so the change is attributed
    /// correctly rather than looking like a user tap.
    func put(key: String, value: JSONValue, source: ToggleSource) async
}

public extension ToggleClient {
    /// A user-driven change — the common case, and what the connection page's
    /// own switches make. Mirrors Kotlin's `source: ToggleSource = UI` default.
    func put(key: String, value: JSONValue) async {
        await put(key: key, value: value, source: .ui)
    }
}

/// The toggle map. A struct rather than a bare dictionary because the
/// connection page renders it as a unit and SwiftUI wants a value type to diff;
/// the contents are exactly Kotlin's `Map<String, JSONValue>`.
public struct Toggles: Sendable {
    public var values: [String: JSONValue]
    public init(values: [String: JSONValue] = [:]) {
        self.values = values
    }
}
