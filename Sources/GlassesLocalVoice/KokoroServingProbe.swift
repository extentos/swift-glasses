// Kokoro serving-speed probe (doc 19 K5d): measures load time + RTF for
// every serving variant ON THE DEVICE — the M1 spike's numbers did not
// transfer (fp32 RTF 0.5-0.76 on M1 became 3-5× realtime on the A14
// in-session), and int8 INVERTED on Apple ARM (slower than fp32 on M1).
// Only a device probe decides. Run from the host app's Lab surface on a
// fresh launch (brain unloaded) so the numbers are uncontended; the
// report also lands in Documents/extentos-probe-report.txt for pulling.

import Foundation
import GlassesCore
import SherpaOnnxC

public enum KokoroServingProbe {

    public struct Variant: Sendable {
        public let name: String
        public let modelFile: String   // relative to Documents/extentos/models
        public let assetsDir: String   // dir holding voices.bin/tokens.txt
        public let provider: String    // "cpu" | "coreml"
        public let threads: Int32
    }

    static let sentences = [
        "I can hear you. How can I assist you today?",
        "I think poker requires strategy, skill, and a good understanding of probabilities.",
    ]

    /// The default matrix: every model bundle found on device × provider ×
    /// threads. Missing bundles are skipped with a report line.
    public static func defaultVariants() -> [Variant] {
        // CPU variants FIRST: the CoreML EP in the current prebuilt
        // onnxruntime throws an uncaught C++ exception (b29 probe crash,
        // SIGABRT via __cxa_throw). Running it LAST + incremental report
        // writes means a crash still yields every CPU number — and the
        // crash itself is the CoreML verdict on this runtime build.
        [
            Variant(name: "fp32 cpu 2t", modelFile: "kokoro/model.onnx", assetsDir: "kokoro", provider: "cpu", threads: 2),
            Variant(name: "fp32 cpu 4t", modelFile: "kokoro/model.onnx", assetsDir: "kokoro", provider: "cpu", threads: 4),
            Variant(name: "int8 cpu 2t", modelFile: "kokoro-int8/model.int8.onnx", assetsDir: "kokoro-int8", provider: "cpu", threads: 2),
            Variant(name: "int8 cpu 4t", modelFile: "kokoro-int8/model.int8.onnx", assetsDir: "kokoro-int8", provider: "cpu", threads: 4),
            Variant(name: "fp32 coreml (may crash)", modelFile: "kokoro/model.onnx", assetsDir: "kokoro", provider: "coreml", threads: 2),
        ]
    }

    /// Runs the matrix sequentially (each engine destroyed before the
    /// next loads). Returns human-readable report lines as they complete
    /// via `onLine`, and writes the full report to Documents.
    public static func run(onLine: @escaping @Sendable (String) -> Void) async -> [String] {
        var lines: [String] = ["KOKORO SERVING PROBE"]
        onLine(lines[0])
        guard let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else { return lines }
        let modelsRoot = docs.appendingPathComponent("extentos/models", isDirectory: true)
        // espeak-ng-data ships once, with the fp32 bundle.
        let espeak = modelsRoot.appendingPathComponent("kokoro/espeak-ng-data").path

        for v in defaultVariants() {
            let modelPath = modelsRoot.appendingPathComponent(v.modelFile).path
            guard FileManager.default.fileExists(atPath: modelPath) else {
                let line = "\(v.name): model absent — skipped"
                lines.append(line); onLine(line)
                continue
            }
            // Announce BEFORE running + persist incrementally: a variant
            // that crashes the process must not take the completed
            // numbers with it, and the last "starting" line names it.
            let starting = "\(v.name): starting…"
            lines.append(starting); onLine(starting)
            writeReport(lines, docs: docs)
            let line = await measure(
                v, modelPath: modelPath,
                voices: modelsRoot.appendingPathComponent("\(v.assetsDir)/voices.bin").path,
                tokens: modelsRoot.appendingPathComponent("\(v.assetsDir)/tokens.txt").path,
                dataDir: espeak
            )
            lines.removeLast()
            lines.append(line); onLine(line)
            writeReport(lines, docs: docs)
        }
        return lines
    }

    private static func writeReport(_ lines: [String], docs: URL) {
        let report = lines.joined(separator: "\n") + "\n"
        try? report.data(using: .utf8)?.write(
            to: docs.appendingPathComponent("extentos-probe-report.txt"))
    }

    private static func measure(
        _ v: Variant, modelPath: String, voices: String, tokens: String, dataDir: String
    ) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: String = modelPath.withCString { model in
                    voices.withCString { voicesC in
                        tokens.withCString { tokensC in
                            dataDir.withCString { dataC in
                                v.provider.withCString { providerC in
                                    var kokoro = SherpaOnnxOfflineTtsKokoroModelConfig()
                                    kokoro.model = model
                                    kokoro.voices = voicesC
                                    kokoro.tokens = tokensC
                                    kokoro.data_dir = dataC
                                    kokoro.length_scale = 1.0
                                    var modelCfg = SherpaOnnxOfflineTtsModelConfig()
                                    modelCfg.kokoro = kokoro
                                    modelCfg.num_threads = v.threads
                                    modelCfg.provider = providerC
                                    var cfg = SherpaOnnxOfflineTtsConfig()
                                    cfg.model = modelCfg
                                    cfg.max_num_sentences = 1

                                    let loadT0 = Date()
                                    guard let tts = SherpaOnnxCreateOfflineTts(&cfg) else {
                                        return "\(v.name): engine FAILED to load"
                                    }
                                    let loadS = Date().timeIntervalSince(loadT0)
                                    defer { SherpaOnnxDestroyOfflineTts(tts) }
                                    let rate = SherpaOnnxOfflineTtsSampleRate(tts)

                                    var parts: [String] = []
                                    for text in Self.sentences {
                                        let t0 = Date()
                                        guard let audio = text.withCString({ c in
                                            SherpaOnnxOfflineTtsGenerate(tts, c, 0, 1.0)
                                        }) else {
                                            parts.append("synthFAIL")
                                            continue
                                        }
                                        let synthS = Date().timeIntervalSince(t0)
                                        let audioS = Double(audio.pointee.n) / Double(rate)
                                        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
                                        parts.append(String(format: "RTF %.2f (%.1fs/%.1fs)", synthS / max(audioS, 0.01), synthS, audioS))
                                    }
                                    return "\(v.name): load \(String(format: "%.1f", loadS))s · " + parts.joined(separator: " · ")
                                }
                            }
                        }
                    }
                }
                cont.resume(returning: result)
            }
        }
    }
}
