import Foundation

final class DefaultToggleClient: ToggleClient, @unchecked Sendable {
    private let stateRef: MutableState<Toggles>
    private let onChange: @Sendable (String, JSONValue, JSONValue, ToggleSource) -> Void

    init(
        initial: Toggles = Toggles(),
        onChange: @escaping @Sendable (String, JSONValue, JSONValue, ToggleSource) -> Void = { _, _, _, _ in }
    ) {
        self.stateRef = MutableState(initial)
        self.onChange = onChange
    }

    var state: any ObservableState<Toggles> { stateRef }

    func get(key: String) -> JSONValue? {
        stateRef.current.values[key]
    }

    /// The single write path, public and internal alike. `source` rides the
    /// change event into telemetry, so a voice- or automation-driven flip is
    /// distinguishable from a user tap.
    func put(key: String, value: JSONValue, source: ToggleSource) {
        let before = stateRef.current
        var next = before.values
        next[key] = value
        stateRef.set(Toggles(values: next))
        let oldV = before.values[key] ?? .null
        if !JSONValue.equal(oldV, value) {
            onChange(key, oldV, value, source)
        }
    }
}

extension JSONValue {
    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)):
            return x.count == y.count && zip(x, y).allSatisfy(JSONValue.equal)
        case (.object(let x), .object(let y)):
            guard x.count == y.count else { return false }
            for (k, vx) in x {
                guard let vy = y[k], JSONValue.equal(vx, vy) else { return false }
            }
            return true
        default: return false
        }
    }
}
