import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

// AudioCaptureSession — drives a single `record_audio` capture using the
// shared mic tap. Subscribes to `SharedAudioInput`, writes each buffer to
// `AVAudioFile`, and exits on whichever of these comes first:
//
//   1. Task cancellation (Sprint 0's stop-condition watcher, or any
//      enclosing async task that's been cancelled). Cooperative — the
//      file is finalized with whatever was written, and a partial
//      `AudioRecording` is returned via .success.
//   2. `maxDurationSeconds` elapsed. Skipped when `maxDurationSeconds`
//      is `nil` (the F-DF-02 default): the capture has no time cap.
//   3. `silenceTimeoutSeconds` of continuous below-threshold buffers
//      (RMS-based, threshold ≈ -40 dBFS).
//
// All exit paths produce a `.success(AudioRecording)`. Failure only
// surfaces when subscribe-to-audio-input fails (audio session denied,
// hardware unavailable). The transcript field stays empty per
// PHASE_6_PLAN.md §5.3 — record_audio writes raw samples; transcription
// is the host app's responsibility via `ai_call`.

#if canImport(AVFAudio)

final class AudioCaptureSession: @unchecked Sendable {
    private let audioInput: any AudioInputSubscribing
    private let config: AudioRecordConfig
    private let outputURL: URL

    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var lastNonSilenceAt: Date
    private var samplesWritten: AVAudioFramePosition = 0
    private var fileSampleRate: Double = 16_000

    init(
        audioInput: any AudioInputSubscribing,
        config: AudioRecordConfig,
        outputURL: URL? = nil
    ) {
        self.audioInput = audioInput
        self.config = config
        self.outputURL = outputURL ?? Self.makeOutputURL()
        self.lastNonSilenceAt = Date()
    }

    /// Run the capture. Returns when one of the exit conditions in the
    /// file header fires. Always finalizes the audio file before
    /// returning so the partial is durable on disk.
    func run() async -> ExtentosResult<AudioRecording, AudioError> {
        let started = Date()
        let id = audioInput.subscribe { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }
        guard let id else {
            return .failure(.platformError(wrapping: AudioCaptureError.audioInputUnavailable))
        }
        defer {
            audioInput.unsubscribe(id)
            finalizeFile()
        }

        // F-DF-02: `nil` maxDurationSeconds = no time cap; capture ends
        // only on silence detection or cancellation. Honored literally —
        // no coercion to a default (was the Android pre-fix bug shape).
        let maxDeadline: Date? = config.maxDurationSeconds.map {
            started.addingTimeInterval(Double(max(0, $0)))
        }
        let silenceWindow = Double(max(0, config.silenceTimeoutSeconds))

        while !Task.isCancelled {
            if let maxDeadline, Date() >= maxDeadline {
                break
            }
            if silenceWindow > 0 {
                let silenceFor = Date().timeIntervalSince(snapshotLastNonSilence())
                if silenceFor >= silenceWindow {
                    break
                }
            }
            // 100ms poll — coarse enough not to spin, fine enough to
            // honor a 1-second silence timeout within the right window.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return .success(buildRecording())
    }

    // MARK: - Tap callback

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        if audioFile == nil {
            // Lazy-open with the actual tap format — Apple's
            // `AVAudioFile.write(from:)` requires the file format to
            // match the buffer format. Caching the sample rate so we
            // can compute durationMs after close.
            let format = buffer.format
            fileSampleRate = format.sampleRate
            do {
                let f = try AVAudioFile(
                    forWriting: outputURL,
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
                audioFile = f
            } catch {
                // Couldn't open file — drop subsequent buffers.
                audioFile = nil
                return
            }
        }
        do {
            try audioFile?.write(from: buffer)
            samplesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // Partial write failure — keep going; on finalize the
            // partial-but-valid file remains.
        }
        if !Self.isSilent(buffer) {
            lastNonSilenceAt = Date()
        }
    }

    private func snapshotLastNonSilence() -> Date {
        lock.lock(); defer { lock.unlock() }
        return lastNonSilenceAt
    }

    // MARK: - Finalize

    private func finalizeFile() {
        lock.lock()
        let f = audioFile
        audioFile = nil
        lock.unlock()
        // ARC + AVAudioFile's deinit closes the file. Explicit `nil`
        // assignment is the documented way to flush.
        _ = f
    }

    private func buildRecording() -> AudioRecording {
        lock.lock()
        let samples = samplesWritten
        let rate = fileSampleRate > 0 ? fileSampleRate : 16_000
        lock.unlock()
        let durationMs = Int64(Double(samples) / rate * 1000)
        return AudioRecording(
            transcript: "",
            audioDurationMs: durationMs,
            rawAudioUri: samples > 0 ? outputURL.absoluteString : nil
        )
    }

    // MARK: - Helpers

    private static func makeOutputURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("extentos-audio-\(UUID().uuidString).caf")
    }

    /// RMS over the float-channel data, threshold ≈ -40 dBFS. Buffers
    /// below this are treated as silence for `silenceTimeoutSeconds`.
    /// Coarse but cheap — same shape Android uses for the equivalent
    /// silence detection.
    static func isSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData else { return true }
        let n = Int(buffer.frameLength)
        if n == 0 { return true }
        var sumSq: Float = 0
        for i in 0..<n {
            let s = data[0][i]
            sumSq += s * s
        }
        let rms = (sumSq / Float(n)).squareRoot()
        return rms < 0.01
    }
}

enum AudioCaptureError: Error, Sendable {
    case audioInputUnavailable
}

#endif // canImport(AVFAudio)
