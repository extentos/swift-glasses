import Foundation

// Phase 4 — deterministic in-process provider for unit tests + the MCP
// `injectAssistantUtterance(text:)` path. Per synthesis #16 / S5
// finding #6.
//
// The Mock provider does NOT open a WebSocket, does NOT consume the
// mic flow as PCM, does NOT pump audio. It's a pure intent-router that
// converts injected text into tool dispatches synchronously, emitting
// the same assistant.* events a real provider would. The agent-driven
// test loop (createSimulatorSession → injectAssistantUtterance →
// assertToolCalled) works identically against Mock and OpenAi providers
// — the only difference is dispatch latency + determinism.
//
// v1 behavior is `.matchToolDescriptions`:
//   1. Receive injected utterance via `injectUtterance` (called either
//      directly OR routed from BrowserSim's `incomingTextFrames`
//      `AsyncStream<JSONValue>` per the S2.M.4 inject-routing fix —
//      the MCP `injectAssistantUtterance` handler sends an
//      `stt_transcript` frame which the BrowserSim transport observes
//      raw + fans out via `incomingTextFrames`).
//   2. Lowercase-substring-token-match against each tool's description
//      (token length >= 3 to keep "the" / "a" / "is" from false-positive)
//   3. First match → dispatch its body with empty args
//   4. Emit assistant.user_spoke (the injected text), assistant.tool_called,
//      tool body runs, assistant.tool_result, then a synthesized
//      assistant.assistant_spoke ("ok, <tool_name>")
//
// History: S1.W.7/S1.W.8 originally routed via `audio.transcriptions()`
// Flow — the dogfood found that subscription chain doesn't activate
// when Mock is the only consumer (see
// `phase-4-sprint1-dogfood-findings.md`). S2.W.0 / S2.M.4 switched to
// a shell-level raw-frame observer on `BrowserSimTransport` that
// bypasses the toggle-gating + Rust-core dispatch entirely.
//
// ~200 LoC by design — keep it simple so behavior is predictable. Real
// LLM quality is `OpenAiAssistantProvider`'s job.
//
// Mirrors `android-library/.../impl/MockAssistantProvider.kt` (commit
// `79b572b` post-S2.W.0).

internal final class MockAssistantProvider: AssistantProviderRuntime, @unchecked Sendable {

    private let config: AssistantConfig
    private let behavior: MockBehavior
    private let transport: any GlassesTransport
    private let onAssistantEvent: @Sendable (AssistantEvent) -> Void

    private let lifecycleLock = NSLock()
    private var running = false
    private var frameSubscription: Task<Void, Never>?

    init(
        config: AssistantConfig,
        behavior: MockBehavior,
        transport: any GlassesTransport,
        onAssistantEvent: @escaping @Sendable (AssistantEvent) -> Void
    ) {
        self.config = config
        self.behavior = behavior
        self.transport = transport
        self.onAssistantEvent = onAssistantEvent
    }

    func start() async throws {
        lifecycleLock.lock()
        if running { lifecycleLock.unlock(); return }
        running = true
        lifecycleLock.unlock()

        // Phase 4 / S2.M.4 inject-routing: subscribe to BrowserSim's
        // shell-level raw-frame observer for `stt_transcript` frames.
        // Any Final transcript is routed to `injectUtterance` — the
        // MCP-injected ones may be tagged `source: "assistant_inject"`
        // but for v1 we accept any Final since Mock is sim-only + the
        // customer doesn't run real mic input through Mock.
        //
        // Only attaches when transport is BrowserSim — Mock is sim-only
        // anyway per the design (real-provider sessions use
        // OpenAi/Gemini). For LocalSim / RealMeta the subscription
        // no-ops; programmatic `injectUtterance(text:)` calls still
        // work for unit tests.
        if let sim = transport as? BrowserSimTransport {
            let stream = sim.incomingTextFrames
            let weakSelf = self
            frameSubscription = Task { [weak weakSelf, stream] in
                for await frame in stream {
                    if Task.isCancelled { return }
                    guard let self = weakSelf else { return }
                    guard case .object(let fields) = frame else { continue }
                    guard case .string(let type) = fields["type"] else { continue }
                    if type != "stt_transcript" { continue }
                    let isFinal: Bool = {
                        if case .bool(let b) = fields["is_final"] { return b }
                        if case .bool(let b) = fields["isFinal"] { return b }
                        return true  // default to true if absent
                    }()
                    if !isFinal { continue }
                    let text: String? = {
                        if case .string(let s) = fields["text"] { return s }
                        if case .string(let s) = fields["transcript"] { return s }
                        return nil
                    }()
                    guard let text else { continue }
                    _ = await self.injectUtterance(text: text)
                }
            }
        }

        onAssistantEvent(.sessionStarted(
            provider: "mock",
            model: nil,
            voice: nil
        ))
    }

    func stop() async {
        lifecycleLock.lock()
        if !running { lifecycleLock.unlock(); return }
        running = false
        let task = frameSubscription
        frameSubscription = nil
        lifecycleLock.unlock()

        task?.cancel()
        onAssistantEvent(.sessionEnded(reason: .user, message: nil))
    }

    /// Inject an utterance for the Mock to interpret. Called either
    /// directly (programmatic test invocation) OR routed from
    /// `audio.transcriptions()` Final transcripts in `start()` (the
    /// production path from MCP `injectAssistantUtterance`).
    ///
    /// Emits:
    ///   1. assistant.user_spoke (the injected text)
    ///   2. assistant.tool_called (if a tool matches)
    ///   3. assistant.tool_result (after the body returns)
    ///   4. assistant.assistant_spoke (synthesized confirmation)
    ///
    /// Returns the matched tool name + dispatch outcome, or an error
    /// message if no tool matched.
    @discardableResult
    func injectUtterance(text: String) async -> InjectOutcome {
        lifecycleLock.lock()
        let isRunning = running
        lifecycleLock.unlock()

        if !isRunning {
            return InjectOutcome(matched: nil, error: "Mock provider session is not running.")
        }

        onAssistantEvent(.userSpoke(transcript: text))

        let matched: ToolDefinition?
        switch behavior {
        case .matchToolDescriptions:
            matched = matchByDescription(text: text)
        }

        guard let matched else {
            let msg = "Mock found no tool matching \(String(text.prefix(60)))"
            onAssistantEvent(.assistantSpoke(transcript: msg))
            return InjectOutcome(matched: nil, error: msg)
        }

        let callId = "mock_call_\(UUID().uuidString)"
        let emptyArgs = JSONValue.object([:])
        onAssistantEvent(.toolCalled(
            name: matched.name,
            args: emptyArgs,
            callId: callId
        ))

        let startNanos = DispatchTime.now().uptimeNanoseconds
        let result: ToolResult
        do {
            result = try await matched.body(emptyArgs)
        } catch {
            result = .err("Mock tool dispatch threw: \(type(of: error)): \(error)")
        }
        let durationMs = Int64((DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000)

        let outputStr: String
        let isErr: Bool
        switch result {
        case .ok(let s): outputStr = s; isErr = false
        case .err(let m): outputStr = m; isErr = true
        }

        onAssistantEvent(.toolResult(
            callId: callId,
            name: matched.name,
            output: outputStr,
            isError: isErr,
            durationMs: durationMs
        ))

        let confirmation = isErr
            ? "sorry, \(matched.name) failed: \(outputStr)"
            : "ok, \(matched.name)"
        onAssistantEvent(.assistantSpoke(transcript: confirmation))

        return InjectOutcome(matched: matched.name, error: nil)
    }

    private func matchByDescription(text: String) -> ToolDefinition? {
        let needle = text.lowercased()
        // Iteration order = registration order (Array preserves insertion).
        return config.tools.first { tool in
            wordsOverlap(needle, tool.description.lowercased())
        }
    }

    private func wordsOverlap(_ a: String, _ b: String) -> Bool {
        let tokensA = a.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        guard !tokensA.isEmpty else { return false }
        return tokensA.contains { b.contains($0) }
    }

    /// Outcome of an inject call — surfaced to the MCP response for
    /// faster agent-test debugging.
    struct InjectOutcome: Sendable {
        let matched: String?
        let error: String?
    }
}
