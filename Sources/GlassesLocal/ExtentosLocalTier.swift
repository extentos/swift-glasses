// GlassesLocal → GlassesCore registration: one bootstrap call makes the
// local tier available to the dashboard switch. GlassesCore's
// `LocalRealtimeProvider` (the Rust-loop shell) asks `LocalTierRegistry`
// for a brain when a `local-*` model id resolves; this file supplies it.
//
// Device-tier default (doc 14, measured 2026-07-19): iPhone-12-class
// (≤4 GB) floor = Qwen 2.5 1.5B 4-bit; larger devices step up the ladder
// as it lands. The dashboard id stays platform-neutral (`local-gemma` et
// al) — which BRAIN serves it is Extentos's per-device call, with
// developer overrides coming with the ladder phase.

import Foundation
import GlassesCore
import os
import MLXLMCommon

public enum ExtentosLocalTier {

    /// Call once at app bootstrap (scaffold-owned line at release).
    public static func register() {
        LocalTierRegistry.brainFactory = { modelId in
            LocalBrainAdapter(config: brainConfig(for: modelId))
        }
        // `local-auto` resolution. GlassesCore owns the seam and the RULE
        // (Rust `resolveAutoModel`); this module owns the ladder and the
        // device readings, which is why the resolver registers from here.
        LocalTierRegistry.autoResolver = { servedRemotely in
            AutoModelSelection.resolve(servedRemotely: servedRemotely)
        }
    }

    /// Per-device fit information for one local model — the SDK surfaces
    /// the facts so APPS can present model options and USERS choose what
    /// to download; the SDK NEVER substitutes a different model for the
    /// chosen one (Asger's rule, 2026-07-24: the choice is sacred — a
    /// too-big selection surfaces an honest doesn't-fit error at the
    /// download/load step, never a silent swap).
    public struct DeviceFit: Sendable {
        public let modelId: String
        /// Estimated process memory the loaded model needs (probe-refined).
        public let requiredMb: Int
        /// Available process memory right now (0 where unknowable — macOS).
        public let availableMb: Int
        public var fits: Bool { availableMb == 0 || availableMb >= requiredMb }
    }

    static let requiredMb: [String: Int] = [
        "local-qwen3-8b": 5800,
        "local-qwen3-0.6b": 500,
        "local-qwen25-1.5b": 1000,
        "local-qwen3-1.7b": 1200,
        "local-qwen3-4b": 2900,
    ]

    /// Fit facts for `dashboardId` on THIS device — the choosing-moment
    /// surface for apps ("needs ~2.9 GB free; this device has ~1.4 GB").
    public static func deviceFit(for dashboardId: String) -> DeviceFit {
        let required = requiredMb[dashboardId] ?? 0
        #if os(iOS)
        let available = Int(os_proc_available_memory()) / (1024 * 1024)
        #else
        let available = 0
        #endif
        return DeviceFit(modelId: dashboardId, requiredMb: required, availableMb: available)
    }

    /// Dashboard id → per-model brain profile (weights + prompt protocol).
    /// Per Asger's direction (2026-07-19): each local model is its OWN
    /// dashboard switch — the unified per-device auto-assignment is
    /// deliberately deferred. Profiles are sim-runner data (doc 16 matrix):
    /// Qwen 3 1.7B = 20/20 tools at the 1.5B's footprint; its profile
    /// carries /no_think (thinking would leak into speech) + the balanced
    /// nudge (spurious 6→2; that clause HURTS the 1.5B, hence per-model).
    static func brainConfig(for dashboardId: String) -> LocalBrain.Config {
        switch dashboardId {
        case "local-qwen25-1.5b":
            return LocalBrain.Config(
                modelId: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                requiredMemoryMb: 1000,
                trace: sessionTrace
            )
        case "local-qwen3-1.7b":
            return qwen3Config
        // Ladder bottom (added 2026-07-25): same generation and template as
        // the 1.7B, so it inherits that profile (balanced nudge +
        // /no_think) until its own Gate-0 pass says otherwise. requiredMb
        // is a conservative estimate — refine from the first on-device
        // probe (the pattern every other rung followed).
        case "local-qwen3-0.6b":
            return LocalBrain.Config(
                modelId: "mlx-community/Qwen3-0.6B-4bit",
                toolNudgeOverride: Self.balancedToolNudge,
                systemSuffix: " /no_think",
                requiredMemoryMb: 500,
                trace: sessionTrace
            )
        // Phase-3 ladder top (Gate-0 verdict 2026-07-24): Qwen3-4B = 20/20
        // tools with the PLAIN nudge — the balanced clause that helps the
        // 1.7B HURT the 4B (17/20), so the profile stays plain (each Qwen
        // generation wants its own nudge; that's what per-model profiles
        // are for). Qwen2.5-3B FAILED Gate-0 outright (0/20 via the native
        // tool-template path) and is not offered. Context stays budgeted —
        // the OpenGlasses lesson: unbudgeted prompts on big models hit
        // uncatchable mid-stream OOM.
        // Ladder top (added 2026-07-25): no current iPhone clears the
        // 5800 MB floor — the pre-load fit check refuses honestly (spoken
        // reason) until high-memory devices arrive. The floor is
        // DELIBERATELY conservative: overestimating refuses, underestimating
        // jetsams mid-load (the Qwen2.5-3B death) — probe-refine on the
        // first device that can host it. Profile mirrors the 4B (same
        // generation: plain nudge, budgeted context).
        case "local-qwen3-8b":
            return LocalBrain.Config(
                modelId: "mlx-community/Qwen3-8B-4bit",
                systemSuffix: " /no_think",
                contextBudgetTokens: 3584,
                requiredMemoryMb: 5800,
                trace: sessionTrace
            )
        case "local-qwen3-4b":
            return LocalBrain.Config(
                modelId: "mlx-community/Qwen3-4B-4bit",
                systemSuffix: " /no_think",
                contextBudgetTokens: 3584,
                requiredMemoryMb: 2900,
                trace: sessionTrace
            )
        default:
            // Legacy `local-gemma` and unknown local-* ids serve the
            // strongest floor brain until their own catalog entries land.
            return qwen3Config
        }
    }

    private static var qwen3Config: LocalBrain.Config {
        LocalBrain.Config(
            modelId: "mlx-community/Qwen3-1.7B-4bit",
            toolNudgeOverride: Self.balancedToolNudge,
            systemSuffix: " /no_think",
            requiredMemoryMb: 1200,
            trace: sessionTrace
        )
    }

    /// Brain cache/reset lines → the SDK's pullable session trace (the
    /// greeting path has no stats hook, so this sink is what makes its
    /// prefill disposition visible in a pulled trace, not just syslog).
    private static let sessionTrace: @Sendable (String) -> Void = {
        LocalTierDiagnostics.shared.record($0)
    }

    /// Runner-validated for Qwen 3 (doc 16): the restraint clause.
    static let balancedToolNudge =
        "(If this request matches one of your tools, respond with the tool call itself; otherwise just answer normally — never call a tool the user didn't ask for.) "
}

/// Bridges GlassesCore's `LocalTurnBrain` seam onto the MLX `LocalBrain`.
final class LocalBrainAdapter: LocalTurnBrain, @unchecked Sendable {

    private let brain: LocalBrain

    init(config: LocalBrain.Config) {
        self.brain = LocalBrain(config: config)
    }

    func warmUp() async throws {
        try await brain.warmUp()
    }

    func prefillPrefix(instructions: String, tools: [LocalBrainTool]) async {
        await brain.prefillPrefix(instructions: instructions, tools: Self.specs(from: tools))
    }

    func runTurn(
        instructions: String,
        userText: String,
        tools: [LocalBrainTool],
        execute: @escaping @Sendable (String, String) async -> String,
        onToolCalled: @escaping @Sendable (String, String) -> Void,
        onToolResult: @escaping @Sendable (String, String) -> Void,
        onReplyChunk: @escaping @Sendable (String) -> Void,
        onStats: @escaping @Sendable (LocalBrainStats) -> Void
    ) async throws -> String? {
        let specs = Self.specs(from: tools)
        let outcome = try await brain.runTurn(
            instructions: instructions,
            userText: userText,
            tools: specs,
            execute: execute,
            hooks: LocalTurnHooks(
                onToolCalled: onToolCalled,
                onToolResult: onToolResult,
                onGenerationInfo: { stats in
                    onStats(LocalBrainStats(
                        promptTokens: stats.promptTokens,
                        generationTokens: stats.generationTokens,
                        promptSeconds: stats.promptSeconds,
                        generateSeconds: stats.generateSeconds,
                        cacheReusedTokens: stats.cacheReusedTokens,
                        cacheDisposition: stats.cacheDisposition
                    ))
                },
                onReplyChunk: onReplyChunk
            )
        )
        switch outcome {
        case .reply(let text): return text
        case .silent: return nil
        }
    }

    func composeGreeting(instructions: String, prompt: String?, tools: [LocalBrainTool]) async throws -> String? {
        // Model-composed greeting (the Greeting.Custom contract): one
        // inference with the greet directive, then the exchange is removed
        // from the brain's history so the conversation starts clean. Tools
        // ride along for prompt-cache prefix consistency (see the protocol
        // doc) — with the start-time warm, the greet prefills only its own
        // directive tokens.
        let directive = prompt ?? "Greet the user in one short spoken sentence."
        let outcome = try await brain.runTurn(
            instructions: instructions,
            userText: "(the user just woke you — greet them) \(directive)",
            tools: Self.specs(from: tools),
            execute: { _, _ in "ok" },
            hooks: LocalTurnHooks()
        )
        await brain.clearHistory()
        if case .reply(let text) = outcome { return text }
        return nil
    }

    func clearHistory() async {
        await brain.clearHistory()
    }

    static func specs(from tools: [LocalBrainTool]) -> [LocalToolSpec] {
        tools.map { tool in
            LocalToolSpec(
                name: tool.name,
                description: tool.description,
                parameters: schemaDict(tool.schemaJson)
            )
        }
    }

    private static func schemaDict(_ json: String?) -> [String: any Sendable] {
        guard
            let json,
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj as? [String: any Sendable] ?? [:]
    }
}
