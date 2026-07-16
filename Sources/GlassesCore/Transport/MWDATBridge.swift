import Foundation

// Single bridge between publisher-style callback APIs and Swift's
// `AsyncStream<T>`. TRANSPORT.md § iOS wiring mandates "every MWDAT
// publisher flows through this bridge; no other async-interop layer is
// required."
//
// The platform-agnostic core (`bridging(_:)`) is defined against a local
// `CancellableListener` protocol so it can be unit-tested on macOS where
// MWDATCore is unavailable. An iOS-only adapter wraps MWDAT's
// `Announcer<T>` / `AnyListenerToken` and funnels through the same core,
// keeping a single bridge path for the whole library.

public protocol CancellableListener: Sendable {
    func cancel() async
}

public extension AsyncStream where Element: Sendable {
    /// Generic publisher bridge. `subscribe` registers the inner `emit`
    /// closure with the underlying callback API and returns a handle whose
    /// `cancel()` tears the subscription down. `cancel()` runs when the
    /// consumer drops the iterator or the continuation is otherwise
    /// finished.
    ///
    /// The `subscribe` closure is *not* `@Sendable` — it runs synchronously
    /// at AsyncStream construction time on the caller's isolation context,
    /// which lets adapters capture non-Sendable publishers (e.g. MWDAT's
    /// `any Announcer<T>`). The inner emit closure is `@Sendable` so the
    /// underlying callback API can deliver events from any thread.
    static func bridging(
        _ subscribe: (@escaping @Sendable (Element) -> Void) -> any CancellableListener
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let listener = subscribe { value in continuation.yield(value) }
            continuation.onTermination = { _ in
                Task { await listener.cancel() }
            }
        }
    }
}

#if os(iOS)
import MWDATCore

final class AnyListenerTokenWrapper: CancellableListener, @unchecked Sendable {
    private let token: any AnyListenerToken
    init(_ token: any AnyListenerToken) { self.token = token }
    func cancel() async { await token.cancel() }
}

extension AsyncStream where Element: Sendable {
    /// Bridges an MWDAT `Announcer<Element>` to `AsyncStream<Element>`.
    /// Delegates to `bridging(_:)` — the single path for publisher-to-stream
    /// plumbing in the library.
    static func fromAnnouncer(
        _ announcer: any Announcer<Element>
    ) -> AsyncStream<Element> {
        bridging { emit in
            AnyListenerTokenWrapper(announcer.listen { value in emit(value) })
        }
    }
}
#endif // os(iOS)
