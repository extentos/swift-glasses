// GlassesLocal — the local realtime tier's iOS brain (v2 program,
// docs/design/free-tier/13 §C-3 + 14 decision 4 + 15 §E).
//
// The brain is ONE effect executor for the Rust `ConversationLoop`: the
// shell's `BeginInference` runs `runTurn`; `CancelInference` cancels the
// Swift Task driving it. The machine never sees tools — the tool loop runs
// entirely in here (doc 13: the THINKING state hides it).
//
// Deliberately NOT ChatSession (verified 2026-07-19): its automatic tool
// loop can leave a dangling tool call in history when cancelled mid-tool
// (the OpenGlasses Plan-BF "one bad tool call bricks the conversation"
// class), and it hides per-tool events the SDK must emit for provider
// parity. We drive the lower-level `generate` stream and own both.
//
// Hygiene contract (doc 15 §E, binding):
//  1. History NEVER contains an assistant tool-call message without a
//     matching tool result — cancellation mid-loop inserts synthetic error
//     results before propagating.
//  2. Customer tool bodies are never half-cancelled: they run in an
//     unstructured Task that does not inherit our cancellation.
//  3. The system+tools prefix is byte-stable across a session (KV/prompt
//     cache friendliness; also doc 11's lesson, independently OpenGlasses').
//
// Cross-turn KV/prompt cache (added after the first hardware run proved the
// baseline): the cache holds EXACTLY the fed prompt tokens — after every
// clean generation the sampled tokens are trimmed back off, so the cache
// state is fully known at all times. Each turn LCP-diffs the new prompt
// against it, trims any divergent tail, and prefills only the suffix (the
// probe's 2.55 s prefill → the new-tokens-only cost). A cancelled stream
// RESETS the cache rather than trusting its offset (the generation task may
// still be appending for a few ms after early termination — mlx-swift-lm's
// own caveat); one cold prefill after a barge-in is the honest price.
//
// Reply streaming: `onReplyChunk` emits sentence-boundary segments during
// generation (the machine's ReplyChunk events — SPEAKING starts at the
// first sentence). Text preceding a tool call streams too: "let me check…"
// filling the tool latency is the production behavior.

import CryptoKit
import Foundation
import GlassesCore
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

public enum GlassesLocalInfo {
    /// The first brain the tier ships (doc 14 decision 4).
    public static let firstBrainModelId = "mlx-community/gemma-4-e2b-it-4bit"
}

/// A customer tool, bridged to the model's schema dialect by the shell
/// (name/description/JSON-schema parameters, OpenAI shape).
public struct LocalToolSpec: Sendable {
    public let name: String
    public let description: String
    /// JSON-schema `parameters` object (OpenAI shape); empty = no-arg tool.
    public let parameters: [String: any Sendable]

    public init(name: String, description: String, parameters: [String: any Sendable]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    var asToolSpec: ToolSpec {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters.isEmpty
                    ? ["type": "object", "properties": [String: any Sendable]()]
                    : parameters,
            ] as [String: any Sendable],
        ]
    }
}

/// Runs one customer tool. Returns the result string; failures are returned
/// as strings too (the model can react) — never thrown.
public typealias LocalToolExecutor = @Sendable (_ name: String, _ argumentsJson: String) async -> String

/// One generate pass's performance numbers (per tool-loop iteration).
public struct LocalGenerationStats: Sendable, Equatable {
    public let promptTokens: Int
    public let generationTokens: Int
    public let promptSeconds: Double
    public let generateSeconds: Double
    /// Prompt tokens served from the cross-turn cache (the LCP kept).
    public let cacheReusedTokens: Int
    /// How the cache aligned for this generate: "warm", "trim(-N)",
    /// "cold(<reset reason>)", or "reprime". A cold turn names the reset
    /// that caused it — the 14.6s-turn lesson: a silent reset is
    /// undiagnosable from the prefill number alone.
    public let cacheDisposition: String
    public var tokensPerSecond: Double {
        generateSeconds > 0 ? Double(generationTokens) / generateSeconds : 0
    }
}

/// Per-tool-call parity events (→ ToolCalled / ToolResultEvent) + perf.
public struct LocalTurnHooks: Sendable {
    public var onToolCalled: @Sendable (_ name: String, _ argumentsJson: String) -> Void
    public var onToolResult: @Sendable (_ name: String, _ output: String) -> Void
    public var onGenerationInfo: @Sendable (LocalGenerationStats) -> Void
    /// A speakable sentence-boundary segment, emitted DURING generation.
    /// Wire it to the machine's ReplyChunk; leave defaulted for whole-reply
    /// behavior (the returned outcome always carries the full text either
    /// way — history and telemetry never depend on this hook).
    public var onReplyChunk: @Sendable (_ text: String) -> Void

    public init(
        onToolCalled: @escaping @Sendable (String, String) -> Void = { _, _ in },
        onToolResult: @escaping @Sendable (String, String) -> Void = { _, _ in },
        onGenerationInfo: @escaping @Sendable (LocalGenerationStats) -> Void = { _ in },
        onReplyChunk: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.onToolCalled = onToolCalled
        self.onToolResult = onToolResult
        self.onGenerationInfo = onGenerationInfo
        self.onReplyChunk = onReplyChunk
    }
}

/// Streaming-safe filter for reasoning-model preambles: Qwen 3 prepends a
/// `<think>…</think>` block (empty in /no_think mode) that must never be
/// spoken or stored — run-10 hardware trace showed it inside the greeting.
/// Holds text until the block's fate is decided, then passes through.
struct ThinkStripper {
    private var buffer = ""
    private var passthrough = false

    mutating func ingest(_ piece: String) -> String {
        if passthrough { return piece }
        buffer += piece
        if buffer.count < 7, "<think>".hasPrefix(buffer) {
            return "" // undecided — could still become an opening tag
        }
        guard buffer.hasPrefix("<think>") else {
            passthrough = true
            let out = buffer
            buffer = ""
            return out
        }
        guard let close = buffer.range(of: "</think>") else {
            return "" // inside the think block — hold everything
        }
        passthrough = true
        let rest = String(buffer[close.upperBound...])
        buffer = ""
        return rest.drop(while: { $0 == "\n" || $0 == " " }).isEmpty
            ? "" : String(rest.drop(while: { $0 == "\n" || $0 == " " }))
    }

    /// Applied to the FULL accumulated text (history/reply hygiene).
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^\s*<think>[\s\S]*?</think>\s*"#,
            with: "",
            options: .regularExpression
        )
    }
}

/// Sentence-boundary accumulator for streamed speech (the OpenGlasses
/// chunking shape — buffer until `.` `!` `?` or newline — implemented
/// fresh). Pure; the brain drives it per generation.
struct SentenceChunker {
    private var buffer = ""
    private static let enders: Set<Character> = [".", "!", "?", "\n"]

    /// Ingest a token-stream piece; returns any newly completed sentences.
    mutating func ingest(_ piece: String) -> [String] {
        buffer += piece
        guard let last = buffer.lastIndex(where: { Self.enders.contains($0) }) else {
            return []
        }
        let end = buffer.index(after: last)
        let complete = String(buffer[..<end])
        buffer = String(buffer[end...])
        let sentence = complete.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? [] : [sentence]
    }

    /// End of generation: whatever remains is the last segment.
    mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }
}

public enum LocalTurnOutcome: Sendable, Equatable {
    case reply(String)
    case silent
}

public enum LocalBrainError: Error {
    case notLoaded
    case toolLoopExceeded(iterations: Int)
    /// The chosen model does not fit this device's available memory. The
    /// SDK never substitutes a smaller model (the choice is sacred) — the
    /// load refuses HONESTLY instead of jetsam-crashing the process
    /// (a 3B-class load kills a 4GB iPhone at load, measured 2026-07).
    case insufficientMemory(requiredMb: Int, availableMb: Int)
}

extension LocalBrainError: SpeakableBrainError {
    /// One spoken sentence per failure mode: what happened + what the user
    /// can do. The provider speaks this instead of a generic apology.
    public var spokenMessage: String {
        switch self {
        case .insufficientMemory:
            return "This phone doesn't have enough memory for the selected "
                + "local model. Please pick a smaller model in your Extentos "
                + "dashboard, then relaunch the app."
        case .notLoaded, .toolLoopExceeded:
            return "Sorry, I ran into a problem."
        }
    }
}

/// The MLX-served brain. One instance per assistant session; an actor so a
/// single turn runs at a time by construction (the machine already
/// guarantees this — the actor is the belt to its braces).
public actor LocalBrain {

    public struct Config: Sendable {
        public var modelId: String
        public var maxTokens: Int
        public var temperature: Float
        public var maxToolIterations: Int
        /// Logit repetition penalty (nil = off). Matrix verdict (doc 16):
        /// no gain on Qwen 2.5 1.5B and actively harmful on Qwen 3
        /// (tool-loop spirals) — stays off; the knob remains for research.
        public var repetitionPenalty: Float?
        public var repetitionContextSize: Int
        /// Override for the per-turn tool nudge (nil = the shipped
        /// `toolRecencyNudge`). Set per model profile (sim-runner data).
        public var toolNudgeOverride: String?
        /// Appended to the system message (byte-stable). Per-model switch
        /// slot — e.g. Qwen 3's "/no_think" (thinking mode would leak
        /// reasoning into spoken replies and wreck latency).
        public var systemSuffix: String?
        /// Session-trace sink for cache/reset lines (the adapter wires it
        /// to the SDK's pullable diagnostics; nil = NSLog only, which keeps
        /// this file free of GlassesCore symbols for the Mac harness).
        public var trace: (@Sendable (String) -> Void)?
        /// Prompt budget (estimated tokens). Oldest history drops to fit —
        /// the OpenGlasses lesson (concept, not code): an unbudgeted prompt
        /// on a big model hits UNCATCHABLE mid-stream OOM; trimming at
        /// submit time is the only safe point. 0 disables.
        public var contextBudgetTokens: Int
        /// Estimated process memory (MB) this model needs loaded. Load
        /// refuses with `insufficientMemory` when the device can't hold it
        /// (honest failure, never a crash, never a substitute). 0 = no
        /// check (harness/macOS).
        public var requiredMemoryMb: Int

        public init(
            modelId: String = GlassesLocalInfo.firstBrainModelId,
            maxTokens: Int = 512,
            temperature: Float = 0.2,
            maxToolIterations: Int = 5,
            repetitionPenalty: Float? = nil,
            repetitionContextSize: Int = 64,
            toolNudgeOverride: String? = nil,
            systemSuffix: String? = nil,
            contextBudgetTokens: Int = 4096,
            requiredMemoryMb: Int = 0,
            trace: (@Sendable (String) -> Void)? = nil
        ) {
            self.repetitionPenalty = repetitionPenalty
            self.repetitionContextSize = repetitionContextSize
            self.toolNudgeOverride = toolNudgeOverride
            self.systemSuffix = systemSuffix
            self.contextBudgetTokens = contextBudgetTokens
            self.requiredMemoryMb = requiredMemoryMb
            self.trace = trace
            self.modelId = modelId
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.maxToolIterations = maxToolIterations
        }
    }

    private let config: Config
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    /// Brain-owned conversation (system prompt excluded; prepended per turn
    /// so the prefix stays byte-stable).
    private var history: [Chat.Message] = []
    /// Cross-turn prompt cache. Invariant: `kvCache` holds the KV state of
    /// EXACTLY `kvTokens` (the fed prompt of the last clean generation —
    /// sampled tokens trimmed back off). Reset to nil whenever that can't
    /// be guaranteed (cancellation, trim failure).
    private var kvCache: [KVCache]?
    private var kvTokens: [Int] = []
    /// Why the cache is currently nil — named at every reset and reported
    /// as the NEXT generate's `cold(<reason>)` disposition, so a cold
    /// prefill in a trace is always attributable.
    private var lastResetReason = "first-use"

    public init(config: Config = Config()) {
        self.config = config
    }

    /// NSLog always (live syslog); the injected sink additionally lands the
    /// line in the SDK's pullable session trace.
    private func traceCache(_ line: String) {
        NSLog("[GlassesLocal] %@", line)
        config.trace?(line)
    }

    /// Load (download on first use via the Hub cache) + hold the model.
    /// Idempotent. Progress ∈ [0,1] for the download phase.
    ///
    /// Transient network failures retry with backoff (mobile Wi-Fi drops
    /// mid-multi-GB-download are NORMAL, not exceptional — iPhone-12 probe,
    /// 2026-07-19; the Hub's chunk cache preserves partial progress across
    /// attempts). Non-network errors surface immediately.
    public func warmUp(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await ensureContainer(progress: progress)
    }

    /// Single-flight load shared by warmUp and runTurn. A turn arriving
    /// while the detached warm-up is still loading AWAITS that load (the
    /// first-wake race: connect fires warmUp in the background, the greeting
    /// composes ~1 s later) — it must never fail notLoaded, and actor
    /// reentrancy must never start a second multi-GB download.
    private func ensureContainer(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        #if os(iOS)
        if config.requiredMemoryMb > 0 {
            let availableMb = Int(os_proc_available_memory()) / (1024 * 1024)
            if availableMb < config.requiredMemoryMb {
                let note = "model \(config.modelId) needs ~\(config.requiredMemoryMb)MB, ~\(availableMb)MB available — load refused (never substituted, never crashed)"
                traceCache(note)
                throw LocalBrainError.insufficientMemory(
                    requiredMb: config.requiredMemoryMb, availableMb: availableMb)
            }
        }
        #endif
        // MLX's buffer cache defaults to Metal's recommendedMaxWorkingSetSize
        // — effectively ALL of RAM on iPhone — so evaluation temporaries
        // accumulate instead of returning to the OS, and the app rides the
        // jetsam ceiling until it dies (measured on the iPhone-12 probe:
        // per-process-limit kill at ~2.05 GB with a 0.95 GB model; the
        // OpenGlasses blueprint documents the identical death and MLX's own
        // iOS guidance is a small cap). Set before any Metal touch, here
        // rather than init so simulator/unit paths never load Metal.
        Memory.cacheLimit = 20 * 1024 * 1024
        let modelId = config.modelId
        // Begin/end markers (b14 postmortem): the b14 trace was BLIND to a
        // wedged load/generate — nothing logs until work completes. Every
        // long-running stage now marks its start so a stall is attributable
        // to a stage, not inferred from silence.
        let traceFn = config.trace
        traceCache("model load begin: \(modelId)")
        let loadStartMs = Int64(Date().timeIntervalSince1970 * 1000)
        let task = Task<ModelContainer, Error> {
            var attempt = 0
            while true {
                attempt += 1
                do {
                    return try await loadModelContainer(
                        from: #hubDownloader(),
                        using: #huggingFaceTokenizerLoader(),
                        id: modelId,
                        progressHandler: { p in progress?(p.fractionCompleted) }
                    )
                } catch {
                    let isNetwork = (error as NSError).domain == NSURLErrorDomain
                    let line = "model load attempt \(attempt) failed (\(isNetwork ? "network" : "fatal")): \(error)"
                    NSLog("[GlassesLocal] %@", line)
                    traceFn?(line)
                    guard isNetwork, attempt < Self.maxDownloadAttempts else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }
            }
        }
        loadTask = task
        do {
            let loaded = try await task.value
            container = loaded
            loadTask = nil
            traceCache("model load done in \(Int64(Date().timeIntervalSince1970 * 1000) - loadStartMs)ms")
            return loaded
        } catch {
            loadTask = nil
            traceCache("model load FAILED: \(error)")
            throw error
        }
    }

    private static let maxDownloadAttempts = 5

    public var isLoaded: Bool { container != nil }

    // ── Operation serialization (b19 wake diagnosis) ─────────────────────
    // The cache invariant assumes STRICTLY SERIAL operations: each captures
    // (kvCache, kvTokens) at entry and writes them at exit. Actor
    // reentrancy broke that at first wake — the app-start warm, the
    // connect-time warm, and the greeting all captured the EMPTY cache
    // before any of them executed, so each re-prefilled the entire prefix
    // from scratch (3 × ~8-9 s cold on a launch-contended GPU = the 25 s
    // "wake sound but no answer"). Every state-capturing operation now
    // waits for its predecessor END-TO-END before capturing.
    private var opTail: Task<Void, Never> = Task {}

    public func clearHistory() {
        history = []
    }

    /// Test seam (harness only): seed a completed exchange so measurements
    /// (e.g. the prefill-throughput sweep) run over known-size,
    /// production-shaped prompts without paying an inference per turn.
    func seedHistoryTurn(user: String, assistant: String) {
        history.append(.user(user))
        history.append(.assistant(assistant))
    }

    /// Test seam (harness only): observable history size — the
    /// truncate-to-heard proof counts entries after a cancelled turn.
    var historyEntryCount: Int { history.count }

    private func systemText(_ instructions: String) -> String {
        config.systemSuffix.map { instructions + $0 } ?? instructions
    }

    /// See runTurn — bisect scenario F, verbatim.
    static let toolRecencyNudge =
        "(Remember: if this request matches one of your tools, respond with the tool call itself.) "

    /// Conservative token estimate (chars ÷ 3 — deliberately OVER-counts
    /// so the budget errs toward trimming; real tokenization happens
    /// inside the container and is too late to trim safely).
    private func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 3)
    }

    /// Drop oldest history until the estimated prompt fits the budget
    /// (never the just-appended current user turn). The prompt cache
    /// self-heals: a trim is an LCP divergence the alignment already
    /// handles. Mid-stream OOM on big models is uncatchable — submit time
    /// is the only safe place to enforce the window.
    private func trimHistoryToBudget(instructions: String) {
        let budget = config.contextBudgetTokens
        guard budget > 0 else { return }
        func estimatedTotal() -> Int {
            var total = estimateTokens(systemText(instructions)) + 64
            for message in history {
                total += estimateTokens(message.content) + 8
            }
            return total
        }
        var dropped = 0
        while history.count > 1, estimatedTotal() > budget {
            history.removeFirst()
            dropped += 1
        }
        if dropped > 0 {
            traceCache("context budget: dropped \(dropped) oldest history entries")
        }
    }

    /// Warm the prompt cache with the session prefix (system + tools) via a
    /// 1-token generation on a canonical dummy turn. The dummy tail is
    /// LCP-trimmed by the first real turn; the expensive system+tools
    /// region stays cached — first-turn/greeting prefill drops to
    /// suffix-only. Never throws and touches no history; a failed warm is
    /// just a cold first turn.
    public func prefillPrefix(instructions: String, tools: [LocalToolSpec]) async {
        let prev = opTail
        let work = Task { [prev] in
            await prev.value
            await self.prefillPrefixInner(instructions: instructions, tools: tools)
        }
        opTail = Task { _ = await work.value }
        await work.value
    }

    private func prefillPrefixInner(instructions: String, tools: [LocalToolSpec]) async {
        // Mid-session, the cache already holds the live history — warmer
        // than the bare prefix this would rebuild. Re-running the dummy-turn
        // warm here LCP-trims the history KV away (the re-wake clobber:
        // connect() re-fires the warm on every wake, and the greeting then
        // re-prefills the entire history it just lost). Prefix warming is a
        // fresh-session tool only.
        guard history.isEmpty else {
            traceCache("prefix warm skipped — session history live, cache kept")
            return
        }
        guard let container = try? await ensureContainer() else { return }
        let toolSpecs = tools.map(\.asToolSpec)
        let chat: [Chat.Message] = [.system(systemText(instructions)), .user("Hi")]
        let input = UserInput(chat: chat, tools: toolSpecs)
        var mutableParams = GenerateParameters()
        mutableParams.maxTokens = 1
        let params = mutableParams

        let cacheIn = kvCache
        let fedIn = kvTokens
        let modelIdIn = config.modelId
        traceCache("prefix warm begin")
        let result: ([KVCache]?, [Int], String?)? = try? await container.perform {
            context -> ([KVCache]?, [Int], String?) in
            let lmInput = try await context.processor.prepare(input: input)
            let fullTokens = lmInput.text.tokens.asArray(Int.self)
            var cache = cacheIn
            var fed = fedIn
            var stateNote: String? = nil
            // Cold-start killer (the Android RDQ #80 design, MLX edition):
            // a fresh brain first tries the persisted prefix state — a
            // safetensors flash read replacing the multi-second prefill.
            // The file is keyed by the exact token ids (+ model id + format
            // salt), so any config/template/tokenizer drift misses cleanly.
            let stateURL = Self.kvStateURL(modelId: modelIdIn, tokens: fullTokens)
            if cache == nil || cache!.isEmpty {
                let t0 = Date()
                if let (restored, restoredTokens) = Self.restoreKVState(
                    url: stateURL, model: context.model, params: params, expected: fullTokens)
                {
                    cache = restored
                    fed = restoredTokens
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    stateNote = "prefix KV restored (\(restoredTokens.count) tokens) in \(ms)ms"
                } else {
                    cache = context.model.newCache(parameters: params)
                    fed = []
                }
            }
            let lcp = zip(fed, fullTokens).prefix(while: { $0.0 == $0.1 }).count
            if lcp < fed.count {
                if cache!.allSatisfy({ $0.isTrimmable }) {
                    for layer in cache! { _ = layer.trim(fed.count - lcp) }
                    fed = Array(fed[..<lcp])
                } else {
                    cache = context.model.newCache(parameters: params)
                    fed = []
                }
            }
            let suffix = Array(fullTokens[fed.count...])
            if suffix.isEmpty { return (cache, fed, stateNote) } // already warm
            let suffixInput = LMInput(text: .init(tokens: MLXArray(suffix)))
            let stream = try MLXLMCommon.generate(
                input: suffixInput, cache: cache, parameters: params,
                context: context, tools: toolSpecs
            )
            for await _ in stream {}
            if Task.isCancelled { return (nil, [], nil) }
            let fedCount = fed.count + suffix.count
            let overrun = cache![0].offset - fedCount
            if overrun > 0, cache!.allSatisfy({ $0.isTrimmable }) {
                for layer in cache! { _ = layer.trim(overrun) }
            }
            if cache![0].offset == fedCount {
                if let saved = Self.saveKVState(url: stateURL, cache: cache!, tokens: fullTokens) {
                    stateNote = saved
                }
                return (cache, fullTokens, stateNote)
            }
            return (nil, [], nil)
        }
        if let (cacheOut, fedOut, stateNote) = result {
            kvCache = cacheOut
            kvTokens = fedOut
            if let stateNote { traceCache(stateNote) }
            if cacheOut == nil {
                lastResetReason = "prefix-warm-desync"
                traceCache("cache reset: prefix-warm-desync")
            } else {
                traceCache("prefix warmed (\(fedOut.count) tokens cached)")
            }
        }
    }

    // ── Prefix-KV persistence (RDQ #80, MLX edition) ─────────────────────
    // The rendered-prefix token ids ARE the invalidation key: model id +
    // exact tokens + format salt hash into the file name, so instructions/
    // tool/template/tokenizer drift lands on a different file (stale ones
    // pruned after each save). Restore validates layer shapes BEFORE
    // touching any cache state and falls back to a cold warm on any
    // mismatch — never a crash.

    private static let kvStateSalt = "mlx-kv1"

    private static func kvStateURL(modelId: String, tokens: [Int]) -> URL? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data(modelId.utf8))
        hasher.update(data: Data(kvStateSalt.utf8))
        let tokens32 = tokens.map(Int32.init)
        tokens32.withUnsafeBufferPointer { hasher.update(data: Data(buffer: $0)) }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)
        let dir = base.appendingPathComponent("extentos/kvcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeId = modelId.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safeId)-\(hash).safetensors")
    }

    private static func restoreKVState(
        url: URL?, model: any LanguageModel, params: GenerateParameters, expected: [Int]
    ) -> ([KVCache], [Int])? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let arrays = try? MLX.loadArrays(url: url),
            let tokenArray = arrays["t"]
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let savedTokens = tokenArray.asArray(Int32.self).map(Int.init)
        guard savedTokens == expected else { return nil }  // belt + braces past the hash
        var cache = model.newCache(parameters: params)
        // Validate EVERYTHING before mutating anything: every layer must be
        // the simple K/V shape and every entry must exist (the state setter
        // traps on arity mismatch — never feed it blind).
        var states: [[MLXArray]] = []
        for i in cache.indices {
            guard cache[i] is KVCacheSimple,
                let k = arrays["c\(i)_0"], let v = arrays["c\(i)_1"]
            else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            states.append([k, v])
        }
        guard arrays.count == cache.count * 2 + 1 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        for (i, layerState) in states.enumerated() {
            cache[i].state = layerState
        }
        return (cache, savedTokens)
    }

    /// Returns a trace note on success, nil on (silent, non-fatal) failure.
    private static func saveKVState(url: URL?, cache: [KVCache], tokens: [Int]) -> String? {
        guard let url else { return nil }
        var arrays: [String: MLXArray] = ["t": MLXArray(tokens.map(Int32.init))]
        for (i, layer) in cache.enumerated() {
            guard layer is KVCacheSimple else { return nil }
            let state = layer.state
            guard state.count == 2 else { return nil }
            arrays["c\(i)_0"] = state[0]
            arrays["c\(i)_1"] = state[1]
        }
        eval(Array(arrays.values))
        guard (try? MLX.save(arrays: arrays, url: url)) != nil else { return nil }
        // Prune stale keys for this model (config drift leaves orphans).
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent.components(separatedBy: "-").dropLast().joined(separator: "-")
        if let siblings = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in siblings
            where f != url && f.lastPathComponent.hasPrefix(prefix)
                && f.pathExtension == "safetensors"
            {
                try? FileManager.default.removeItem(at: f)
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        return "prefix KV saved (\(bytes / 1_000_000) MB) → \(url.lastPathComponent)"
    }

    /// Drive one full user turn: generate → dispatch tools → regenerate,
    /// until a spoken reply (or silence). Cancellation (the machine's
    /// CancelInference) lands between steps; the hygiene contract holds on
    /// every exit path.
    public func runTurn(
        instructions: String,
        userText: String,
        tools: [LocalToolSpec],
        execute: @escaping LocalToolExecutor,
        hooks: LocalTurnHooks = LocalTurnHooks()
    ) async throws -> LocalTurnOutcome {
        let prev = opTail
        let work = Task { [prev] in
            await prev.value
            // A turn cancelled while still queued must never touch history
            // or the cache.
            try Task.checkCancellation()
            return try await self.runTurnInner(
                instructions: instructions, userText: userText,
                tools: tools, execute: execute, hooks: hooks
            )
        }
        opTail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func runTurnInner(
        instructions: String,
        userText: String,
        tools: [LocalToolSpec],
        execute: @escaping LocalToolExecutor,
        hooks: LocalTurnHooks
    ) async throws -> LocalTurnOutcome {
        let container = try await ensureContainer()

        let toolSpecs = tools.map(\.asToolSpec)
        // Recency-anchored tool reminder — the bisect-proven fix (doc 16,
        // 2026-07-19): two chat turns of precedent flip this model class
        // from 100% tool calling to 0% ("I can't physically take a
        // picture…"); a constant reminder ADJACENT to the request restores
        // 3/3 where a few-shot example in the system prompt restores 0/3.
        // Ships verbatim as scenario F tested it; byte-stable per turn.
        let nudge = config.toolNudgeOverride ?? Self.toolRecencyNudge
        let modelUserText = tools.isEmpty ? userText : nudge + userText
        history.append(.user(modelUserText))
        trimHistoryToBudget(instructions: instructions)

        for _ in 0..<config.maxToolIterations {
            try Task.checkCancellation()

            let chat: [Chat.Message] = [.system(systemText(instructions))] + history
            // Sendable across the container boundary: UserInput (not
            // Chat.Message arrays) and an immutable GenerateParameters.
            let input = UserInput(chat: chat, tools: toolSpecs)
            var mutableParams = GenerateParameters()
            mutableParams.maxTokens = config.maxTokens
            mutableParams.temperature = config.temperature
            mutableParams.repetitionPenalty = config.repetitionPenalty
            mutableParams.repetitionContextSize = config.repetitionContextSize
            let params = mutableParams

            let cacheIn = kvCache
            let fedIn = kvTokens
            let resetReasonIn = lastResetReason
            traceCache("gen begin: history=\(history.count) cached=\(fedIn.count) tok")
            let (text, toolCalls, cacheOut, fedOut, alignment, resetNote, spoken) = try await container.perform {
                context -> (String, [ToolCall], [KVCache]?, [Int], String, String?, String) in
                let lmInput = try await context.processor.prepare(input: input)
                let fullTokens = lmInput.text.tokens.asArray(Int.self)

                // ── Prompt-cache alignment (invariant: cache == fed) ──
                var cache = cacheIn
                var fed = fedIn
                var disposition = "warm"
                if cache == nil || cache!.isEmpty {
                    cache = context.model.newCache(parameters: params)
                    fed = []
                    disposition = "cold(\(resetReasonIn))"
                }
                let lcp = zip(fed, fullTokens).prefix(while: { $0.0 == $0.1 }).count
                if lcp < fed.count {
                    // Divergent tail (history edit / template boundary):
                    // trim it, or start cold if this cache can't trim.
                    if cache!.allSatisfy({ $0.isTrimmable }) {
                        for layer in cache! { _ = layer.trim(fed.count - lcp) }
                        fed = Array(fed[..<lcp])
                        disposition = "trim(-\(fedIn.count - lcp))"
                    } else {
                        cache = context.model.newCache(parameters: params)
                        fed = []
                        disposition = "cold(untrimmable-divergence)"
                    }
                }
                var suffix = Array(fullTokens[fed.count...])
                if suffix.isEmpty {
                    // Identical prompt (degenerate) — re-prime on the last
                    // token so generation has an input.
                    for layer in cache! { _ = layer.trim(1) }
                    fed.removeLast()
                    suffix = [fullTokens[fullTokens.count - 1]]
                    disposition = "reprime"
                }
                let cacheAlignment =
                    "cache: \(disposition) reused=\(fed.count) prefill=\(suffix.count) total=\(fullTokens.count)"
                let reusedTokens = fed.count

                let suffixInput = LMInput(text: .init(tokens: MLXArray(suffix)))
                // Inlined from MLXLMCommon.generate(input:cache:...): that
                // wrapper DISCARDS the producer task; we keep it so a
                // cancelled generation can be JOINED. Upstream's own doc
                // comment prescribes generateTask for chat-session callers
                // (early-terminated streams keep computing into the KVCache
                // for a few ms — the exact race the old discard guarded).
                let iterator = try TokenIterator(
                    input: suffixInput, model: context.model,
                    cache: cache, parameters: params
                )
                let (stream, producer) = MLXLMCommon.generateTask(
                    promptTokenCount: suffixInput.text.tokens.size,
                    modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer,
                    iterator: iterator,
                    tools: toolSpecs
                )
                var text = ""
                var calls: [ToolCall] = []
                // Sentences actually handed to the mouth — the closest
                // brain-side proxy for "what the user heard" (doc 13's
                // truncate-to-heard, the interrupted-turn history record).
                var spokenSoFar = ""
                var chunker = SentenceChunker()
                var thinkStripper = ThinkStripper()
                for await generation in stream {
                    switch generation {
                    case .chunk(let piece):
                        text += piece
                        if !Task.isCancelled {
                            let speakable = thinkStripper.ingest(piece)
                            for sentence in chunker.ingest(speakable) {
                                hooks.onReplyChunk(sentence)
                                spokenSoFar += spokenSoFar.isEmpty ? sentence : " " + sentence
                            }
                        }
                    case .toolCall(let call): calls.append(call)
                    case .info(let info):
                        hooks.onGenerationInfo(LocalGenerationStats(
                            promptTokens: info.promptTokenCount,
                            generationTokens: info.generationTokenCount,
                            promptSeconds: info.promptTime,
                            generateSeconds: info.generateTime,
                            cacheReusedTokens: reusedTokens,
                            cacheDisposition: disposition
                        ))
                    @unknown default: break
                    }
                }

                if Task.isCancelled {
                    // Cancel-preserving cache (doc 18 §A — the fix for the
                    // b17 cancel × cold-prefill spiral): our early exit
                    // cancelled the producer via stream termination. JOIN
                    // it — its final act is Stream().synchronize(), after
                    // which the cache is provably quiescent — then restore
                    // the invariant exactly like the clean path, instead of
                    // discarding the session's warm KV.
                    await producer.value
                    let fedTotal = fed.count + suffix.count
                    let offset = cache![0].offset
                    if offset > fedTotal {
                        guard cache!.allSatisfy({ $0.isTrimmable }) else {
                            return (text, calls, nil, [], cacheAlignment, "cancelled-untrimmable", spokenSoFar)
                        }
                        for layer in cache! { _ = layer.trim(offset - fedTotal) }
                    }
                    // A mid-prefill cancel keeps the completed prefix —
                    // still valid KV, still warm for the next turn.
                    let kept = min(offset, fedTotal)
                    guard cache![0].offset == kept else {
                        return (text, calls, nil, [], cacheAlignment, "cancelled-desync", spokenSoFar)
                    }
                    return (text, calls, cache, Array(fullTokens.prefix(kept)),
                            cacheAlignment + " cancel-kept=\(kept)/\(fedTotal)", nil, spokenSoFar)
                }
                // Flush the sentence remainder (a reply ending without an
                // ender, or pre-tool text like "let me check").
                if let rest = chunker.flush() { hooks.onReplyChunk(rest) }

                // ── Restore the invariant: trim sampled tokens back off ──
                let fedCount = fed.count + suffix.count
                let overrun = cache![0].offset - fedCount
                if overrun > 0, cache!.allSatisfy({ $0.isTrimmable }) {
                    for layer in cache! { _ = layer.trim(overrun) }
                }
                if cache![0].offset == fedCount {
                    return (text, calls, cache, fullTokens, cacheAlignment, nil, "")
                }
                return (text, calls, nil, [], cacheAlignment, "post-generate-desync", "")
            }
            kvCache = cacheOut
            kvTokens = fedOut
            traceCache(alignment)
            if cacheOut == nil, let resetNote {
                lastResetReason = resetNote
                traceCache("cache reset: \(resetNote)")
            }
            // Truncate-to-heard (doc 13 §E, the second half finally
            // implemented): an interrupted reply records what was actually
            // handed to the mouth, closing the exchange — otherwise the
            // model sees an unanswered question and gravitates back to the
            // OLD thread instead of the user's new one (the b18/b20
            // "keeps repeating the same thing" steering failure). Nothing
            // spoken → no entry: the next utterance is simply the next
            // turn over the still-open question.
            if Task.isCancelled, !spoken.isEmpty {
                history.append(.assistant(spoken))
                traceCache("truncate-to-heard: kept \(spoken.count) chars")
            }
            // A cancelled generate exits its stream early — never speak or
            // dispatch from a partial generation.
            try Task.checkCancellation()

            if toolCalls.isEmpty {
                NSLog("[GlassesLocal] turn done — mlx active=%dMB cache=%dMB",
                      Memory.activeMemory / 1_048_576, Memory.cacheMemory / 1_048_576)
                let reply = ThinkStripper.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reply.isEmpty else { return .silent }
                history.append(.assistant(reply))
                return .reply(reply)
            }

            // Tool phase. The assistant tool-call message and its results
            // are appended as a CLOSED pair on every exit path (hygiene 1).
            history.append(.assistant(ThinkStripper.strip(text), toolCalls: toolCalls))
            var cancelled = false
            for call in toolCalls {
                let argsJson = Self.argumentsJson(of: call)
                if cancelled || Task.isCancelled {
                    history.append(.tool("tool execution was interrupted", id: call.id))
                    cancelled = true
                    continue
                }
                hooks.onToolCalled(call.function.name, argsJson)
                // Unstructured Task: customer tool bodies never inherit our
                // cancellation (hygiene 2).
                let runner = Task { await execute(call.function.name, argsJson) }
                let output = await runner.value
                history.append(.tool(output, id: call.id))
                hooks.onToolResult(call.function.name, output)
            }
            if cancelled { throw CancellationError() }
        }
        throw LocalBrainError.toolLoopExceeded(iterations: config.maxToolIterations)
    }

    private static func argumentsJson(of call: ToolCall) -> String {
        guard
            let data = try? JSONEncoder().encode(call.function.arguments),
            let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }
}
