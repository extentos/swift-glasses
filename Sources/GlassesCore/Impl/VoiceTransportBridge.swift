import Foundation

// Forwards `VoiceClient.hints` + `VoiceClient.stats` snapshots to the
// simulator browser tab as `app_voice_hints` frames over
// `BrowserSimTransport.sendOutbound`. The simulator's Voice Commands
// panel subscribes to this frame to render click-to-fire chips.
//
// No-op on non-BrowserSim transports (RealMeta / LocalSim have no
// browser to forward to).
//
// Wire shape (full snapshot per emit, snake_case JSON keys verbatim
// from the cross-platform contract):
//
//   {
//     "type": "app_voice_hints",
//     "hints": [
//       {
//         "id": "v_start_recording_1",
//         "phrase": "start recording",
//         "label": "Record",
//         "stops": ["stop recording"],
//         "is_active": false,
//         "has_handler": true,
//         "fired_count": 0,
//         "last_fired_at_ms": null
//       }
//     ]
//   }
//
// Why full snapshots: hints register/cancel rarely; stats updates are
// frequent but emit-on-change + JSON-string dedup keeps the wire quiet.
// Simulator-side state is "replace the local list with what arrived" —
// no merge / dedup logic on either end.
//
// Reconnect force-emit: a steady-state dedup'd stream alone misses two
// consumer-arrival cases — (1) the browser binds AFTER the app has
// already emitted its frame (the backend hub drops `app_voice_hints`
// until a browser is present), and (2) the transport drops and
// reconnects onto a fresh in-memory hub with no cached frame. Both share
// one shape: a fresh consumer became reachable upstream of where state
// was already published. So the bridge force-emits a fresh snapshot —
// bypassing the dedup — on `SimulatorHint.browserReconnected` and on
// every `GlassesState.active` re-entry after the first. Duplicate frames
// in steady state are harmless (the simulator just replaces its list).
//
// Mirrors `android-library/.../impl/VoiceTransportBridge.kt`.

internal final class VoiceTransportBridge: @unchecked Sendable {
    private let transport: any GlassesTransport
    private let voice: any VoiceClient
    private let connection: any ConnectionClient
    private var task: Task<Void, Never>?

    init(
        transport: any GlassesTransport,
        voice: any VoiceClient,
        connection: any ConnectionClient
    ) {
        self.transport = transport
        self.voice = voice
        self.connection = connection
    }

    /// Begin observing hints + stats. No-op when the transport isn't
    /// BrowserSim. The task runs until the surrounding library is shut
    /// down via `stop()` or the transport closes.
    func start() {
        guard let sim = transport as? BrowserSimTransport else { return }
        let hintsStream = voice.hints.stream
        let statsStream = voice.stats.stream
        let simulatorHintStream = connection.simulatorHint.stream
        let connectionStateStream = connection.state.stream
        let merger = FrameMerger(sim: sim)
        task = Task { [hintsStream, statsStream, simulatorHintStream, connectionStateStream, merger] in
            await withTaskGroup(of: Void.self) { group in
                // Steady state: change-driven emissions, deduped by the merger.
                group.addTask {
                    for await next in hintsStream {
                        if Task.isCancelled { return }
                        await merger.updateHints(next)
                    }
                }
                group.addTask {
                    for await next in statsStream {
                        if Task.isCancelled { return }
                        await merger.updateStats(next)
                    }
                }
                // Force-emit when the simulator browser (re)connects — a
                // frame sent before the browser was bound was dropped by
                // the backend hub, so a fresh snapshot must follow.
                group.addTask {
                    for await hint in simulatorHintStream {
                        if Task.isCancelled { return }
                        if case .browserReconnected? = hint {
                            await merger.forceEmit()
                        }
                    }
                }
                // Force-emit on session re-establishment. The first
                // `.active` is the initial attach — already covered by the
                // hints/stats streams replaying their current value on
                // subscribe — so it is dropped; every later `.active` is a
                // reconnect onto a fresh hub that has no cached frame.
                group.addTask {
                    var sawActive = false
                    for await state in connectionStateStream {
                        if Task.isCancelled { return }
                        guard state.active != nil else { continue }
                        if sawActive {
                            await merger.forceEmit()
                        } else {
                            sawActive = true
                        }
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Serialises the cross-stream merge + send. ObservableState.stream
    /// replays the current value on subscribe, so the first emit from
    /// each side primes the merger before we send anything to the
    /// transport. `lastSent` dedups via a JSON-string compare — cheap,
    /// and keeps redundant frames off the wire when one side emits
    /// without changing the visible snapshot. `forceEmit()` bypasses the
    /// dedup for a consumer that just (re)connected.
    private actor FrameMerger {
        private let sim: BrowserSimTransport
        private var hints: [VoiceHint] = []
        private var stats: [String: VoiceHintStats] = [:]
        private var lastSent: String? = nil

        init(sim: BrowserSimTransport) {
            self.sim = sim
        }

        func updateHints(_ next: [VoiceHint]) async {
            hints = next
            await flush(force: false)
        }

        func updateStats(_ next: [String: VoiceHintStats]) async {
            stats = next
            await flush(force: false)
        }

        /// Re-send the current snapshot even if unchanged — for a consumer
        /// that just (re)connected and holds no cached frame.
        func forceEmit() async {
            await flush(force: true)
        }

        private func flush(force: Bool) async {
            let frame = VoiceTransportBridge.buildFrame(hints: hints, stats: stats)
            guard let serialized = VoiceTransportBridge.serialize(frame) else { return }
            if !force && serialized == lastSent { return }
            lastSent = serialized
            sim.sendOutbound(frame)
        }
    }

    fileprivate static func buildFrame(
        hints: [VoiceHint],
        stats: [String: VoiceHintStats]
    ) -> [String: Any] {
        var hintEntries: [[String: Any]] = []
        hintEntries.reserveCapacity(hints.count)
        for h in hints {
            let s = stats[h.id]
            var entry: [String: Any] = [
                "id": h.id,
                "phrase": h.phrase,
                "label": h.label,
                "stops": h.stops,
                "is_active": h.isActive,
                "has_handler": h.hasHandler,
                "fired_count": s?.firedCount ?? 0,
            ]
            if let lastMs = s?.lastFiredAtMs {
                entry["last_fired_at_ms"] = lastMs
            } else {
                entry["last_fired_at_ms"] = NSNull()
            }
            hintEntries.append(entry)
        }
        return [
            "type": "app_voice_hints",
            "hints": hintEntries,
        ]
    }

    fileprivate static func serialize(_ frame: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(frame),
              let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
