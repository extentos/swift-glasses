import Foundation

// Lock-protected `ObservableState<T>` implementation. `current` is a
// synchronous read; `stream` returns a fresh AsyncStream that replays the
// current value once and then yields every subsequent mutation. Matches
// StateFlow semantics from the Kotlin library.

final class MutableState<Element: Sendable>: ObservableState, @unchecked Sendable {
    typealias Element = Element

    private let lock = NSLock()
    private var value: Element
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    init(_ initial: Element) { self.value = initial }

    var current: Element {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    var stream: AsyncStream<Element> {
        AsyncStream { cont in
            let token = UUID()
            self.lock.lock()
            let current = self.value
            self.continuations[token] = cont
            self.lock.unlock()
            cont.yield(current)
            cont.onTermination = { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock()
                _ = self.continuations.removeValue(forKey: token)
                self.lock.unlock()
            }
        }
    }

    func set(_ next: Element) {
        lock.lock()
        value = next
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(next) }
    }

    func update(_ transform: (Element) -> Element) {
        lock.lock()
        let next = transform(value)
        value = next
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(next) }
    }

    func drain() {
        lock.lock()
        let conts = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in conts { c.finish() }
    }
}
