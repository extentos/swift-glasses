import Foundation

public protocol ToggleClient: Sendable {
    var state: any ObservableState<Toggles> { get }
    func update(_ transform: @Sendable (Toggles) -> Toggles) async
}

public struct Toggles: Sendable {
    public var values: [String: JSONValue]
    public init(values: [String: JSONValue] = [:]) {
        self.values = values
    }
}
