import Foundation

public protocol ObservableState<Element>: Sendable {
    associatedtype Element: Sendable
    var current: Element { get }
    var stream: AsyncStream<Element> { get }
}
