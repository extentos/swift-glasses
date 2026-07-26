// Measurement-only observation of the ears (segmenter arc step 1, doc 16
// postmortem): the b11 regression shipped thresholds with no hardware
// evidence. This meter records what the glasses mic ACTUALLY measures —
// ambient floor, speech levels, trailing tails, endpoint→final latency,
// partial cadence — into the session trace. ZERO behavior: it never
// influences endpointing; the production 900 ms / 0.012 path is untouched.

import Foundation

struct EarsMeter {

    // Candidate thresholds under observation (b11's failed 0.008 included —
    // the data will say whether it sits above or below the ambient floor).
    static let observedThresholds: [Double] = [0.004, 0.008, 0.012]
    static let windowMs: Int64 = 5_000
    static let tailMs: Int64 = 500
    static let utteranceSampleCap = 3_000

    // Rolling ambient window.
    private var window: [Double] = []
    private var windowStartMs: Int64 = 0

    // Utterance tracking at the PRODUCTION onset threshold (observation).
    private var utteranceActive = false
    private var utteranceStartMs: Int64 = 0
    private var samples: [(rms: Double, at: Int64)] = []
    private var firstPartialDelayMs: Int64?
    private var lastPartialAtMs: Int64 = 0
    private var partialGaps: [Int64] = []
    private var endpointFiredAtMs: Int64?

    /// Per-buffer observation; occasionally returns an ambient summary line.
    mutating func tick(rms: Double, nowMs: Int64) -> String? {
        if windowStartMs == 0 { windowStartMs = nowMs }
        window.append(rms)

        if rms >= PlatformSttEngine.speechRmsThreshold, !utteranceActive {
            utteranceActive = true
            utteranceStartMs = nowMs
            samples.removeAll(keepingCapacity: true)
            firstPartialDelayMs = nil
            partialGaps.removeAll(keepingCapacity: true)
            endpointFiredAtMs = nil
        }
        if utteranceActive, samples.count < Self.utteranceSampleCap {
            samples.append((rms, nowMs))
        }

        guard nowMs - windowStartMs >= Self.windowMs, !window.isEmpty else { return nil }
        let sorted = window.sorted()
        let above = Self.observedThresholds.map { t in
            let n = window.filter { $0 >= t }.count
            return String(format: "%.0f%%@%.3f", Double(n) * 100 / Double(window.count), t)
        }.joined(separator: " ")
        let line = String(
            format: "ears: 5s rms p10/p50/p90 = %.4f/%.4f/%.4f (%d bufs) above: %@",
            Self.pct(sorted, 0.10), Self.pct(sorted, 0.50), Self.pct(sorted, 0.90),
            window.count, above
        )
        window.removeAll(keepingCapacity: true)
        windowStartMs = nowMs
        return line
    }

    mutating func notePartial(nowMs: Int64) {
        guard utteranceActive else { return }
        if firstPartialDelayMs == nil {
            firstPartialDelayMs = nowMs - utteranceStartMs
        } else if lastPartialAtMs > 0 {
            partialGaps.append(nowMs - lastPartialAtMs)
        }
        lastPartialAtMs = nowMs
    }

    mutating func noteEndpointFired(nowMs: Int64) {
        endpointFiredAtMs = nowMs
    }

    /// Utterance summary at the final; resets utterance state.
    mutating func noteFinal(nowMs: Int64) -> String? {
        defer {
            utteranceActive = false
            lastPartialAtMs = 0
        }
        guard utteranceActive, !samples.isEmpty else { return nil }
        let endpointAt = endpointFiredAtMs ?? nowMs
        let speech = samples.map(\.rms).sorted()
        let tail = samples.filter { $0.at >= endpointAt - Self.tailMs - 900 && $0.at <= endpointAt - 900 }
            .map(\.rms).sorted()
        let gaps = partialGaps.sorted()
        return String(
            format: "ears: utt dur=%dms endpoint→final=%dms firstPartial=+%dms partialGap p50=%dms rms p50/p90=%.4f/%.4f tail p50=%.4f",
            endpointAt - utteranceStartMs,
            nowMs - endpointAt,
            firstPartialDelayMs ?? -1,
            gaps.isEmpty ? -1 : gaps[gaps.count / 2],
            Self.pct(speech, 0.50), Self.pct(speech, 0.90),
            tail.isEmpty ? -1 : Self.pct(tail, 0.50)
        )
    }

    private static func pct(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[idx]
    }
}
