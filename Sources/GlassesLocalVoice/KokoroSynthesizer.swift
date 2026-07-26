// GlassesLocalVoice — the local tier's on-device neural voice (rung 2,
// doc 19). Kokoro-82M served by sherpa-onnx's OfflineTts: C API pinned at
// v1.13.4, phonemization handled inside the framework (bundled
// espeak-ng-data), CPU-only inference — the K2 spike measured RTF 0.5-0.76
// on 2 M1 threads, so synthesis never contends with the brain's GPU.
//
// A SEPARATE product from GlassesLocal so the sherpa/onnxruntime binaries
// only land on apps that opt into the voice (the same reason GlassesLocal
// keeps MLX off non-local consumers). One bootstrap line:
// `ExtentosLocalVoice.register()`.

import Foundation
import GlassesCore
import SherpaOnnxC

public enum ExtentosLocalVoice {
    /// Call once at app bootstrap (scaffold-owned line at release).
    public static func register() {
        LocalVoiceRegistry.synthesizerFactory = { voiceId in
            // The core owns the id→speaker table (one map, both platforms).
            // A non-Kokoro id returns nil, so the provider serves the system
            // voice exactly as before.
            guard let sid = kokoroSpeakerId(voiceId: voiceId) else { return nil }
            return KokoroSynthesizer(speakerId: Int32(sid))
        }
    }

    /// Where the model bundle lives (dev-seeded for K5; the lazy-download
    /// store lands in K4): Documents/extentos/models/kokoro/ containing
    /// model.onnx, voices.bin, tokens.txt, espeak-ng-data/.
    public static var modelDirectory: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("extentos/models/kokoro", isDirectory: true)
    }
}

/// Mutable state shared with the C progress callback (boxed through the
/// `arg` pointer): the cancel flag and the emit sink.
private final class SynthesisBox: @unchecked Sendable {
    let lock = NSLock()
    var cancelled = false
    var emitted = 0
    let sampleRate: Int32
    let emit: @Sendable (Data, Int32) -> Void
    init(sampleRate: Int32, emit: @escaping @Sendable (Data, Int32) -> Void) {
        self.sampleRate = sampleRate
        self.emit = emit
    }
}

/// C callback: float samples → PCM16 → emit; returns 0 to abort when
/// cancelled. Top-level (no captures) — state rides the arg pointer.
private func kokoroChunkCallback(
    samples: UnsafePointer<Float>?, n: Int32, arg: UnsafeMutableRawPointer?
) -> Int32 {
    guard let arg else { return 1 }
    let box = Unmanaged<SynthesisBox>.fromOpaque(arg).takeUnretainedValue()
    box.lock.lock()
    let cancelled = box.cancelled
    box.lock.unlock()
    if cancelled { return 0 }
    guard let samples, n > 0 else { return 1 }
    var pcm = Data(capacity: Int(n) * 2)
    for i in 0..<Int(n) {
        let clamped = max(-1.0, min(1.0, samples[i]))
        var v = Int16(clamped * 32767.0)
        withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
    }
    box.lock.lock()
    box.emitted += Int(n)
    box.lock.unlock()
    box.emit(pcm, box.sampleRate)
    return 1
}

/// sherpa-onnx-served Kokoro. The C calls are BLOCKING — they run on a
/// dedicated serial queue, never on the cooperative pool. One synthesis at
/// a time by construction (the provider's mouth is single-owner).
public actor KokoroSynthesizer: LocalVoiceSynthesizer {

    private let queue = DispatchQueue(label: "com.extentos.kokoro", qos: .userInitiated)
    private var tts: OpaquePointer?
    private var sampleRate: Int32 = 0
    private var currentBox: SynthesisBox?
    private var loading = false

    /// Which of the model's eleven voices to speak with. They all live in the
    /// one `voices.bin` already on disk, so a different speaker costs no extra
    /// download, memory or load time. The core's KOKORO_SPEAKERS table owns
    /// the id→speaker mapping for both platforms.
    private let speakerId: Int32

    public init(speakerId: Int32 = 0) {
        self.speakerId = speakerId
    }

    public func isReady() async -> Bool { tts != nil }

    public func warmUp() async {
        guard tts == nil, !loading else { return }
        guard let dir = ExtentosLocalVoice.modelDirectory else { return }
        let modelPath = dir.appendingPathComponent("model.onnx").path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            NSLog("[GlassesLocalVoice] kokoro model absent — system voice serves (%@)", dir.path)
            return
        }
        loading = true
        defer { loading = false }
        let voicesPath = dir.appendingPathComponent("voices.bin").path
        let tokensPath = dir.appendingPathComponent("tokens.txt").path
        let dataDirPath = dir.appendingPathComponent("espeak-ng-data").path
        let (handle, rate) = await withCheckedContinuation {
            (cont: CheckedContinuation<(OpaquePointer?, Int32), Never>) in
            queue.async {
                let result: (OpaquePointer?, Int32) = modelPath.withCString { model in
                    voicesPath.withCString { voices in
                        tokensPath.withCString { tokens in
                            dataDirPath.withCString { dataDir in
                                var kokoro = SherpaOnnxOfflineTtsKokoroModelConfig()
                                kokoro.model = model
                                kokoro.voices = voices
                                kokoro.tokens = tokens
                                kokoro.data_dir = dataDir
                                kokoro.length_scale = 1.0
                                var modelCfg = SherpaOnnxOfflineTtsModelConfig()
                                modelCfg.kokoro = kokoro
                                modelCfg.num_threads = 2
                                modelCfg.provider = UnsafePointer(strdup("cpu"))
                                var cfg = SherpaOnnxOfflineTtsConfig()
                                cfg.model = modelCfg
                                cfg.max_num_sentences = 1
                                guard let tts = SherpaOnnxCreateOfflineTts(&cfg) else {
                                    return (nil, 0)
                                }
                                let rate = SherpaOnnxOfflineTtsSampleRate(tts)
                                return (tts, rate)
                            }
                        }
                    }
                }
                cont.resume(returning: result)
            }
        }
        tts = handle
        sampleRate = rate
        if handle != nil {
            NSLog("[GlassesLocalVoice] kokoro ready (%d Hz)", rate)
        } else {
            NSLog("[GlassesLocalVoice] kokoro engine FAILED to load")
        }
    }

    public func synthesize(
        _ text: String,
        emit: @escaping @Sendable (_ pcm16: Data, _ sampleRate: Int32) -> Void
    ) async -> Double? {
        guard let tts, sampleRate > 0 else { return nil }
        let box = SynthesisBox(sampleRate: sampleRate, emit: emit)
        currentBox = box
        defer { currentBox = nil }
        let rate = sampleRate
        let totalSamples: Int = await withCheckedContinuation {
            (cont: CheckedContinuation<Int, Never>) in
            queue.async {
                let arg = Unmanaged.passRetained(box).toOpaque()
                let audio = text.withCString { cText in
                    SherpaOnnxOfflineTtsGenerateWithCallbackWithArg(
                        tts, cText, self.speakerId, 1.0, kokoroChunkCallback, arg
                    )
                }
                var n = 0
                if let audio {
                    n = Int(audio.pointee.n)
                    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
                }
                Unmanaged<SynthesisBox>.fromOpaque(arg).release()
                cont.resume(returning: n)
            }
        }
        box.lock.lock()
        let cancelled = box.cancelled
        box.lock.unlock()
        guard !cancelled, totalSamples > 0 else { return nil }
        return Double(totalSamples) / Double(rate)
    }

    public func cancel() async {
        guard let box = currentBox else { return }
        box.lock.lock()
        box.cancelled = true
        box.lock.unlock()
    }
}
