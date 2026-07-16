import Foundation

final class DefaultToggleClient: ToggleClient, @unchecked Sendable {
    private let stateRef: MutableState<Toggles>
    private let onChange: @Sendable (String, JSONValue, JSONValue) -> Void

    init(initial: Toggles = Toggles(), onChange: @escaping @Sendable (String, JSONValue, JSONValue) -> Void = { _, _, _ in }) {
        self.stateRef = MutableState(initial)
        self.onChange = onChange
    }

    var state: any ObservableState<Toggles> { stateRef }

    func update(_ transform: @Sendable (Toggles) -> Toggles) async {
        let before = stateRef.current
        let after = transform(before)
        stateRef.set(after)
        // Emit per-key change events for any values that changed.
        for (k, newV) in after.values {
            let oldV = before.values[k] ?? .null
            if !JSONValue.equal(oldV, newV) {
                onChange(k, oldV, newV)
            }
        }
        // Deletions also count as changes to null.
        for (k, oldV) in before.values where after.values[k] == nil {
            onChange(k, oldV, .null)
        }
    }

    /// Internal write path for `set_toggle` actions — bypasses the public
    /// `update` closure to avoid forcing callers to rebuild the whole
    /// `Toggles` struct.
    func put(key: String, value: JSONValue) {
        let before = stateRef.current
        var next = before.values
        next[key] = value
        stateRef.set(Toggles(values: next))
        let oldV = before.values[key] ?? .null
        if !JSONValue.equal(oldV, value) {
            onChange(key, oldV, value)
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
