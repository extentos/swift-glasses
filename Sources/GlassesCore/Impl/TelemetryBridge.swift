import Foundation

// Subscribes to transport-level signals (stream lifecycle, connection state,
// toggle changes, meter exhaustion) and translates them into downsampled,
// payload-stripped telemetry events per docs/mcp/TELEMETRY.md § Event catalog.
//
// Mirrors the Android TelemetryBridge: sub-clients stay ignorant of whether
// telemetry is enabled, emitting plain RuntimeEvents. If consent=false the
// DefaultTelemetryClient no-ops, so this bridge can run unconditionally.

protocol StreamLifecycleHook: Sendable {
    func onStart(streamType: String, props: [String: JSONValue]) async
    func onStop(streamType: String, props: [String: JSONValue], durationMs: Int64) async

    /// A discrete capture finished — photo, bounded video clip, or audio clip.
    /// Streams report through onStart/onStop; the one-shot primitives reported
    /// nothing, so `capture_photo` — the flagship capability — had no telemetry
    /// at all. `errorCode` is the field that answers "why did it fail".
    /// Mirrors `StreamLifecycleHook.onCapture` in DefaultAudioClient.kt.
    func onCapture(
        kind: String,
        outcome: String,
        durationMs: Int64?,
        errorCode: String?,
        source: String?,
        sizeBytes: Int64?
    ) async

    /// A speak() finished, was cancelled, or failed. `bargedIn` separates the
    /// wearer talking over it from a programmatic cancelSpeak.
    func onSpeak(
        outcome: String,
        durationMs: Int64?,
        bargedIn: Bool?,
        charCount: Int?,
        errorCode: String?
    ) async
}

// Default no-ops so existing conformers (and test doubles) need not implement
// the discrete-capture half. Matches the Kotlin interface's default methods.
extension StreamLifecycleHook {
    func onCapture(
        kind: String,
        outcome: String,
        durationMs: Int64?,
        errorCode: String?,
        source: String?,
        sizeBytes: Int64?
    ) async {}

    func onSpeak(
        outcome: String,
        durationMs: Int64?,
        bargedIn: Bool?,
        charCount: Int?,
        errorCode: String?
    ) async {}
}

// Wrap an AsyncStream so that the supplied StreamLifecycleHook fires
// stream.started when the consumer begins iterating and stream.stopped
// when the underlying stream finishes or the consumer cancels. The props
// map is forwarded verbatim to the hook.
enum StreamLifecycleWrap {
    static func wrap<T: Sendable>(
        _ stream: AsyncStream<T>,
        streamType: String,
        props: [String: JSONValue],
        hook: any StreamLifecycleHook
    ) -> AsyncStream<T> {
        AsyncStream<T> { continuation in
            let startMs = Int64(Date().timeIntervalSince1970 * 1000)
            let propsCopy = props
            let typeCopy = streamType
            let task = Task {
                await hook.onStart(streamType: typeCopy, props: propsCopy)
                for await value in stream {
                    continuation.yield(value)
                }
                let durationMs = Int64(Date().timeIntervalSince1970 * 1000) - startMs
                await hook.onStop(streamType: typeCopy, props: propsCopy, durationMs: durationMs)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

actor TelemetryBridge: StreamLifecycleHook {
    private let telemetry: DefaultTelemetryClient
    private let transportChosen: TransportChosen
    private let nowMs: @Sendable () -> Int64

    private var connectingStartMs: Int64?
    private var activeStartMs: Int64?
    private var wasActive: Bool = false

    // Retained so strong-self captures in the subscriber closures keep the
    // bridge alive for the lifetime of its streams. A test (or app) that
    // only holds a transitive reference via e.g. `let (_, _, _) = …` would
    // otherwise see the bridge deallocate before the EventLogger register
    // Task runs, silently losing every emitted event.
    private var eventsTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    init(
        telemetry: DefaultTelemetryClient,
        eventLogger: EventLogger,
        connectionState: any ObservableState<GlassesState>,
        transportChosen: TransportChosen,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.telemetry = telemetry
        self.transportChosen = transportChosen
        self.nowMs = nowMs

        // Assign Task handles as the final init step. The subscriber
        // closures capture `self` strongly so the bridge stays alive as
        // long as either stream is producing — callers can discard the
        // bridge reference (tests often do) and rely on the actor+Task
        // pair to self-retain until the producers finish.
        self.eventsTask = nil
        self.stateTask = nil
        let eventsStream = eventLogger.events()
        let stateStream = connectionState.stream
        let self_ = self
        Task { await self_.attachStreams(eventsStream: eventsStream, stateStream: stateStream) }
    }

    deinit {
        eventsTask?.cancel()
        stateTask?.cancel()
    }

    private func attachStreams(
        eventsStream: AsyncStream<RuntimeEvent>,
        stateStream: AsyncStream<GlassesState>
    ) {
        let bridge = self
        eventsTask = Task.detached {
            for await ev in eventsStream {
                await bridge.handleRuntimeEvent(ev)
            }
        }
        stateTask = Task.detached {
            for await s in stateStream {
                await bridge.handleConnectionState(s)
            }
        }
    }

    // StreamLifecycleHook -------------------------------------------------

    func onStart(streamType: String, props: [String: JSONValue]) {
        var merged: [String: JSONValue] = ["streamType": .string(streamType)]
        for (k, v) in props { merged[k] = v }
        telemetry.emitBaseline(name: "stream.started", properties: merged)
    }

    func onStop(streamType: String, props: [String: JSONValue], durationMs: Int64) {
        var merged: [String: JSONValue] = [
            "streamType": .string(streamType),
            "durationMs": .int(durationMs),
        ]
        for (k, v) in props { merged[k] = v }
        telemetry.emitBaseline(name: "stream.stopped", properties: merged)
    }

    func onCapture(
        kind: String,
        outcome: String,
        durationMs: Int64?,
        errorCode: String?,
        source: String?,
        sizeBytes: Int64?
    ) {
        var props: [String: JSONValue] = [
            "kind": .string(kind),
            "outcome": .string(outcome),
        ]
        if let d = durationMs { props["durationMs"] = .int(d) }
        // Only on failure, and only the variant NAME — never a message, which
        // can quote whatever the caller passed in.
        if let e = errorCode { props["errorCode"] = .string(e) }
        if let s = source { props["source"] = .string(s) }
        if let b = sizeBytes { props["sizeBytes"] = .int(b) }
        telemetry.emitBaseline(name: "capture.completed", properties: props)
    }

    func onSpeak(
        outcome: String,
        durationMs: Int64?,
        bargedIn: Bool?,
        charCount: Int?,
        errorCode: String?
    ) {
        var props: [String: JSONValue] = ["outcome": .string(outcome)]
        if let d = durationMs { props["durationMs"] = .int(d) }
        if let b = bargedIn { props["bargedIn"] = .bool(b) }
        // A LENGTH, never the utterance.
        if let c = charCount { props["charCount"] = .int(Int64(c)) }
        if let e = errorCode { props["errorCode"] = .string(e) }
        telemetry.emitBaseline(name: "speak.completed", properties: props)
    }

    // RuntimeEvent mapping ------------------------------------------------

    private func handleRuntimeEvent(_ ev: RuntimeEvent) {
        switch ev {
        case .toggleChanged(let key, _, _, let source):
            telemetry.emitBaseline(name: "toggle.changed", properties: [
                "key": .string(key),
                "source": .string(toggleSourceWire(source)),
            ])

        // A capability refused because of a hardware condition. Without this a
        // developer sees a capture fail and cannot tell whether their code is
        // wrong or the glasses were folded shut.
        case .coexistenceWarning(let blocked, _):
            telemetry.emitBaseline(name: "device.condition_changed", properties: [
                "condition": .string("audio_route"),
                "state": .string("blocked"),
                "blockedCapability": .string(blocked),
            ])

        default:
            break
        }
    }

    // Connection state ---------------------------------------------------

    private func handleConnectionState(_ state: GlassesState) {
        switch state {
        case .connecting:
            if connectingStartMs == nil { connectingStartMs = nowMs() }

        case .active:
            if !wasActive {
                let timeToConnectMs: Int64? = connectingStartMs.map { nowMs() - $0 }
                activeStartMs = nowMs()
                wasActive = true
                connectingStartMs = nil
                var props: [String: JSONValue] = ["transportType": .string(transportChosen.wireValue)]
                if let t = timeToConnectMs { props["timeToConnectMs"] = .int(t) }
                telemetry.emitBaseline(name: "connection.opened", properties: props)
            }

        case .disconnected(let cause):
            if wasActive {
                let duration: Int64? = activeStartMs.map { nowMs() - $0 }
                var props: [String: JSONValue] = [
                    "cause": .string(mapDisconnectCause(cause)),
                ]
                if let d = duration { props["durationMs"] = .int(d) }
                for (k, v) in buildDisconnectExtras(cause) { props[k] = v }
                telemetry.emitBaseline(name: "connection.closed", properties: props)
                wasActive = false
                activeStartMs = nil
            }
            connectingStartMs = nil

        default:
            break
        }
    }

    private func mapDisconnectCause(_ c: DisconnectCause) -> String {
        switch c {
        case .userRequested: return "user_requested"
        case .deviceDroppedConnection: return "device_dropped"
        case .thermalCritical: return "thermal_critical"
        case .hingesClosed: return "hinges_closed"
        case .simulatorSessionExpired: return "session_expired"
        case .simulatorBrowserClosed: return "browser_closed"
        case .simulatorMeterExhausted: return "meter_exhausted"
        case .transportFailure: return "transport_failure"
        }
    }

    private func buildDisconnectExtras(_ c: DisconnectCause) -> [String: JSONValue] {
        switch c {
        case .simulatorSessionExpired(let reason, _):
            return ["sessionExpireReason": .string(sessionExpireReasonWire(reason))]
        case .transportFailure(let cause):
            return ["transportErrorCode": .string(String(describing: type(of: cause)))]
        default:
            return [:]
        }
    }

    private func sessionExpireReasonWire(_ r: SessionExpireReason) -> String {
        switch r {
        case .idleTimeout: return "idle_timeout"
        case .lifetimeCap: return "lifetime_cap"
        case .userEnded: return "user_ended"
        case .backendRestart: return "backend_restart"
        case .unknown: return "unknown"
        }
    }

    private func toggleSourceWire(_ s: ToggleSource) -> String {
        switch s {
        case .ui: return "ui"
        case .voiceCommand: return "voice"
        case .automationTrigger: return "automation"
        }
    }
}
