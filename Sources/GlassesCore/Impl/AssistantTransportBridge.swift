import Foundation

// Forward `assistant.*` lifecycle events to the simulator browser via the
// transport's outbound JSON path. Only attaches when the transport is
// `BrowserSimTransport` — RealMeta + LocalSim don't have a sim UI to
// display them.
//
// ## Wire shape
//
// Each event maps 1:1 to a top-level JSON frame keyed by the
// event-registry schema name (`assistant.session_started`,
// `assistant.tool_called`, etc. — dotted-namespace convention). Field
// names are **snake_case** matching the event-registry schemas at
// `event-registry/runtime/assistant.*.v1.schema.json` and Android's
// `AssistantTransportBridge.kt` byte-for-byte.
//
// ## Lifecycle
//
// Started once at `ExtentosGlasses.create()` (S1.M.11 wiring).
// Subscribes to the eventLogger's `events()` stream for the library's
// lifetime (until `stop()`). No force-emit on reconnect — assistant
// events are momentary (not state), so a fresh consumer just starts
// catching new events.
//
// Mirrors `android-library/.../impl/AssistantTransportBridge.kt` (commit
// `3ade958`).

internal final class AssistantTransportBridge: @unchecked Sendable {
    private let transport: any GlassesTransport
    private let eventLogger: EventLogger
    private var task: Task<Void, Never>?

    init(transport: any GlassesTransport, eventLogger: EventLogger) {
        self.transport = transport
        self.eventLogger = eventLogger
    }

    func start() {
        guard let sim = transport as? BrowserSimTransport else { return }
        let stream = eventLogger.events()
        task = Task { [stream] in
            for await event in stream {
                if Task.isCancelled { return }
                guard case .assistant(let assistantEvent) = event else { continue }
                sim.sendOutbound(Self.buildFrame(assistantEvent))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Build the JSON frame for a given `AssistantEvent`. Internal (not
    /// private) so tests can assert the per-variant wire shape without
    /// spinning up an EventLogger + BrowserSimTransport. Keyed by the
    /// event-registry schema's event name (dotted namespace); field
    /// names snake_case to match the schemas + Android's `buildFrame`
    /// output byte-for-byte.
    internal static func buildFrame(_ event: AssistantEvent) -> [String: Any] {
        switch event {
        case .sessionStarted(let provider, let model, let voice):
            return [
                "type": "assistant.session_started",
                "provider": provider,
                "model": model as Any? ?? NSNull(),
                "voice": voice as Any? ?? NSNull(),
            ]
        case .sessionEnded(let reason, let message):
            return [
                "type": "assistant.session_ended",
                "reason": reason.rawValue,
                "message": message as Any? ?? NSNull(),
            ]
        case .wentDormant:
            return [
                "type": "assistant.went_dormant",
            ]
        case .userSpoke(let transcript):
            return [
                "type": "assistant.user_spoke",
                "transcript": transcript,
            ]
        case .assistantSpoke(let transcript):
            return [
                "type": "assistant.assistant_spoke",
                "transcript": transcript,
            ]
        case .toolCalled(let name, let args, let callId):
            return [
                "type": "assistant.tool_called",
                "name": name,
                "args": Self.jsonValueToAny(args),
                "call_id": callId,
            ]
        case .toolResult(let callId, let name, let output, let isError, let durationMs):
            return [
                "type": "assistant.tool_result",
                "call_id": callId,
                "name": name,
                "output": output,
                "is_error": isError,
                "duration_ms": Int(durationMs),
            ]
        case .reconnected(let reason, let downtimeMs):
            return [
                "type": "assistant.reconnected",
                "reason": reason.rawValue,
                "downtime_ms": Int(downtimeMs),
            ]
        case .error(let kind, let message):
            return [
                "type": "assistant.error",
                "kind": kind,
                "message": message,
            ]
        }
    }

    /// `JSONValue` → `Any` for `JSONSerialization`-compatible payloads.
    /// `BrowserSimTransport.sendOutbound` serializes via
    /// `JSONSerialization.data(withJSONObject:)`, which requires
    /// `[String: Any]` / `[Any]` / `NSNumber` / `NSString` / `NSNull`
    /// leaves — not Swift enums.
    private static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = jsonValueToAny(v) }
            return out
        }
    }
}
