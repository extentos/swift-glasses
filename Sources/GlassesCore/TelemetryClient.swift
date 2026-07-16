import Foundation

public protocol TelemetryClient: Sendable {
    func setUserSegment(_ segment: String?)
    func trackEvent(name: String, properties: [String: JSONValue])
    var consent: Bool { get }
}

public extension TelemetryClient {
    func trackEvent(name: String) {
        trackEvent(name: name, properties: [:])
    }
}
