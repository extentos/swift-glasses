// Ears tape — NDJSON timing/level events for offline decider replay: the
// noisy-room calibration dataset the b11 rule requires before any ears
// threshold ships. Records RMS levels, partial WORD COUNTS, and marks —
// never transcript text. One fresh tape per engine lifetime, ring-capped
// so it can never grow unbounded. Failures are swallowed: measurement must
// never break audio.
//
// Pull:  python -m pymobiledevice3 apps pull <bundle> \
//          Documents/extentos-ears-tape.ndjson <local>

import Foundation

@MainActor
final class EarsTape {
    static let maxBytes = 2 * 1024 * 1024
    static let flushEvery = 32

    private var handle: FileHandle?
    private var opened = false
    private var buffer: [String] = []
    private var bytesWritten = 0
    private var full = false

    func tick(rms: Double, nowMs: Int64) {
        append("{\"t\":\(nowMs),\"rms\":\(String(format: "%.4f", rms))}")
    }

    func notePartial(nowMs: Int64, words: UInt32) {
        append("{\"t\":\(nowMs),\"partial\":\(words)}")
    }

    func noteFinal(nowMs: Int64) {
        append("{\"t\":\(nowMs),\"final\":1}")
    }

    func noteMark(_ mark: String, nowMs: Int64) {
        append("{\"t\":\(nowMs),\"mark\":\"\(mark)\"}")
    }

    private func append(_ line: String) {
        guard EarsTuning.tapeRecorder, !full else { return }
        buffer.append(line)
        if buffer.count >= Self.flushEvery { flush() }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        let chunk = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll(keepingCapacity: true)
        guard let data = chunk.data(using: .utf8) else { return }
        if !opened {
            opened = true
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("extentos-ears-tape.ndjson")
            guard let url else { return }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
            if bytesWritten > Self.maxBytes {
                full = true
                try? handle.write(contentsOf: Data("{\"tape\":\"full\"}\n".utf8))
            }
        } catch {
            full = true // disk trouble: stop trying, never disturb audio
        }
    }
}
