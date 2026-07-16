import Foundation

// Post pure-SDK pivot: minimal `RuntimeClient` impl that just relays the
// shared `EventLogger`. No spec runtime, no voice-command matcher, no
// trigger dispatch. Mirrors
// `android-library/.../impl/DefaultRuntimeClient.kt`.

final class DefaultRuntimeClient: RuntimeClient, @unchecked Sendable {
    private let eventLogger: EventLogger

    init(eventLogger: EventLogger) {
        self.eventLogger = eventLogger
    }

    var events: AsyncStream<RuntimeEvent> {
        eventLogger.events()
    }

    func snapshotEvents() async -> [RuntimeEvent] {
        await eventLogger.snapshot()
    }
}
