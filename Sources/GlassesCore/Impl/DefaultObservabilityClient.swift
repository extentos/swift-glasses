import Foundation

// DefaultObservabilityClient — emits ai_call_start / ai_call_end frames
// to the BrowserSimTransport so customer-side BYOK calls surface under
// getEventLog's "ai" filter. See ObservabilityClient.swift for the
// public contract.
//
// The frames are only sent when the active transport is the simulator
// relay; RealMeta + LocalSim short-circuit to a no-op. This keeps the
// wrapper safe to leave in production code (zero overhead off-sim).
//
// Duration is measured monotonically via DispatchTime.now — not
// Date() — so a wall-clock change during a long call doesn't skew
// the number reported on the wire.

final class DefaultObservabilityClient: ObservabilityClient, @unchecked Sendable {
    private let transport: any GlassesTransport

    init(transport: any GlassesTransport) {
        self.transport = transport
    }

    func aiCall<T: Sendable>(
        label: String,
        metadata: [String: String],
        failureReason: (@Sendable (T) -> String?)?,
        block: @Sendable () async throws -> T
    ) async rethrows -> T {
        // Start/end frames pair around `block`. Since Phase 2a Stage 3,
        // `BrowserSimTransport.sendOutbound` is non-async (the underlying
        // core call is sync), so this is a plain do/catch with no actor
        // hops between the call and the surrounding frame emits.
        let sim = transport as? BrowserSimTransport
        if let sim = sim {
            sim.sendOutbound(startFrame(label: label, metadata: metadata))
        }
        let startNs = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try await block()
            // Two ways to fail, and only one of them throws. Keying success on
            // "did not throw" reported every typed failure as a success.
            let returnedFailure = failureReason?(result)
            if let sim = sim {
                let durationMs = Int64((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000)
                sim.sendOutbound(endFrame(
                    label: label,
                    durationMs: durationMs,
                    error: nil,
                    returnedFailure: returnedFailure
                ))
            }
            return result
        } catch {
            if let sim = sim {
                let durationMs = Int64((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000)
                sim.sendOutbound(endFrame(
                    label: label,
                    durationMs: durationMs,
                    error: error,
                    returnedFailure: nil
                ))
            }
            throw error
        }
    }

    private func startFrame(label: String, metadata: [String: String]) -> [String: Any] {
        // The "ai_" prefix is load-bearing — backend/event-log.ts
        // classifies any type starting with "ai_" into layer: "ai".
        // Renaming this string requires a coordinated backend update.
        var frame: [String: Any] = [
            "type": "ai_call_start",
            "label": label,
        ]
        if !metadata.isEmpty {
            frame["metadata"] = metadata
        }
        return frame
    }

    private func endFrame(
        label: String,
        durationMs: Int64,
        error: Error?,
        returnedFailure: String?
    ) -> [String: Any] {
        var frame: [String: Any] = [
            "type": "ai_call_end",
            "label": label,
            "duration_ms": durationMs,
            "success": error == nil && returnedFailure == nil,
        ]
        if let returnedFailure = returnedFailure, error == nil {
            // The caller's own variant name, so the log reads "keyRejected"
            // rather than a generic marker.
            frame["error_class"] = String(returnedFailure.prefix(64))
        }
        if let error = error {
            // Surface the error class + first-line message so the
            // event log entry is self-describing. Avoid emitting the
            // full message (could leak API keys / PII embedded in
            // upstream error bodies) — keep to one line, capped at 200
            // chars.
            frame["error_class"] = String(describing: type(of: error))
            let raw = error.localizedDescription
            let firstLine = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? raw
            let truncated = String(firstLine.prefix(200))
            if !truncated.isEmpty {
                frame["error_message"] = truncated
            }
        }
        return frame
    }
}
