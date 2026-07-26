// Hosted local brain — BROWSER-SIM serving of the local tier (decision:
// shared-context/decisions-in-flight/local-models-sim-serving-and-sacred-
// choice.md). When the transport is the browser simulator, the selected
// local-* model is served SERVER-SIDE: the managed gateway routes local-*
// chat completions to Extentos's own inference machine running the SAME
// model the SDK runs on-device (llama-swap keys ARE the dashboard ids —
// the id you chose is the id served). Same model, zero downloads, and it
// works even when the app never linked GlassesLocal (this file is MLX-free
// on purpose). Real hardware always runs on-device.
//
// Shape mirrors the on-device brain's seam semantics: history lives inside
// the brain, tool exchanges commit as they complete (their side effects
// happened), a cancelled turn keeps only what actually ran, and
// composeGreeting is one greet-directive turn erased from history after.

import Foundation

enum HostedLocalBrainError: Error {
    case notAuthenticated
    case badResponse(status: Int, body: String)
    case malformedResponse
}

actor HostedLocalBrain: LocalTurnBrain {

    private let model: String
    private let backing: AssistantBacking
    /// OpenAI-shaped chat messages (system is rebuilt per turn, not stored).
    private var history: [[String: Any]] = []

    /// Voice replies are short; bound generation so a runaway completion on
    /// the CPU inference machine can't stall a sim turn for minutes.
    private let maxTokens = 512
    /// History budget, mirroring the on-device brain's contextBudgetTokens
    /// discipline (chars/3 estimate, oldest-first trim). With healthy server
    /// prompt caching, history is nearly free — this bounds the worst case
    /// (a trim changes the cached prefix, so one re-prefill follows; same
    /// trade the on-device cache makes).
    private let historyBudgetTokens = 3584
    /// First request may pay the machine's scale-to-zero wake + model load
    /// (~15-40 s). prefillPrefix pre-pays this off the wake path.
    private let requestTimeout: TimeInterval = 120

    init(model: String, backing: AssistantBacking) {
        self.model = model
        self.backing = backing
    }

    // ── LocalTurnBrain ───────────────────────────────────────────────────

    func warmUp() async throws {
        // Nothing to load app-side; the server-side warm rides prefillPrefix.
    }

    /// The on-device semantic — pre-pay the cold cost long before the wake —
    /// maps here to: wake the scale-to-zero machine, make llama-swap load
    /// the selected model, and warm its prompt cache with the real session
    /// prefix. Best-effort; errors surface on the first real turn instead.
    func prefillPrefix(instructions: String, tools: [LocalBrainTool]) async {
        // Once a conversation exists, the server's cache already holds a
        // LONGER prefix than this ping would prime — sending the bare
        // static prefix would only trim history KV out of the slot and make
        // the next turn re-prefill it (the on-device cache discipline,
        // hosted edition). Warm only when there's nothing to protect.
        guard history.isEmpty else { return }
        let messages: [[String: Any]] = [systemMessage(instructions)]
        _ = try? await post(messages: messages, tools: tools, maxTokensOverride: 1)
    }

    func runTurn(
        instructions: String,
        userText: String,
        tools: [LocalBrainTool],
        execute: @escaping @Sendable (_ name: String, _ argsJson: String) async -> String,
        onToolCalled: @escaping @Sendable (_ name: String, _ argsJson: String) -> Void,
        onToolResult: @escaping @Sendable (_ name: String, _ output: String) -> Void,
        onReplyChunk: @escaping @Sendable (_ text: String) -> Void,
        onStats: @escaping @Sendable (LocalBrainStats) -> Void
    ) async throws -> String? {
        let t0 = Date()
        var promptTokens = 0, cachedTokens = 0, genTokens = 0

        trimHistoryToBudget()

        // Turn additions commit to history on EVERY exit path (defer):
        // completed tool exchanges really executed, so a cancelled turn keeps
        // them and drops only the never-produced reply — abort-safe hygiene.
        var additions: [[String: Any]] = [["role": "user", "content": userText]]
        defer { history.append(contentsOf: additions) }

        for _ in 0 ..< 8 {
            try Task.checkCancellation()
            let base = [systemMessage(instructions)] + history
            // STREAMED request (hardware parity for perceived latency): the
            // on-device brain hands the mouth each sentence as it forms, so
            // speech starts ~1-2s into generation. Sentences flow to
            // onReplyChunk the moment their boundary arrives in the SSE
            // stream; the full text is still returned for history.
            let result = try await postStreaming(
                messages: base + additions,
                tools: tools,
                onSentence: onReplyChunk
            )
            promptTokens += result.usage?.prompt ?? 0
            cachedTokens += result.usage?.cached ?? 0
            genTokens += result.usage?.completion ?? 0

            if !result.toolCalls.isEmpty {
                let calls = result.toolCalls
                    .sorted { $0.key < $1.key }
                    .map { (_, tc) -> [String: Any] in
                        [
                            "type": "function",
                            "id": tc.id.isEmpty ? UUID().uuidString : tc.id,
                            "function": ["name": tc.name, "arguments": tc.args.isEmpty ? "{}" : tc.args],
                        ]
                    }
                var assistantMsg: [String: Any] = ["role": "assistant", "tool_calls": calls]
                if !result.content.isEmpty { assistantMsg["content"] = result.content }
                additions.append(assistantMsg)
                for call in calls {
                    let id = call["id"] as? String ?? UUID().uuidString
                    let fn = call["function"] as? [String: Any]
                    let name = fn?["name"] as? String ?? ""
                    let args = fn?["arguments"] as? String ?? "{}"
                    onToolCalled(name, args)
                    let output = await execute(name, args)
                    onToolResult(name, output)
                    additions.append(["role": "tool", "tool_call_id": id, "content": output])
                }
                continue
            }

            let text = stripThink(result.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onStats(LocalBrainStats(
                promptTokens: promptTokens,
                generationTokens: genTokens,
                promptSeconds: 0,
                generateSeconds: Date().timeIntervalSince(t0),
                cacheReusedTokens: cachedTokens,
                cacheDisposition: "hosted"
            ))
            if text.isEmpty { return nil }
            additions.append(["role": "assistant", "content": text])
            return text
        }
        // Tool-loop ceiling: give a silent turn rather than an error mid-chat.
        return nil
    }

    func composeGreeting(instructions: String, prompt: String?, tools: [LocalBrainTool]) async throws -> String? {
        // Mirror of the on-device greeting: one greet-directive turn, then the
        // exchange is erased so the conversation starts clean.
        let directive = prompt ?? "Greet the user in one short spoken sentence."
        let text = try await runTurn(
            instructions: instructions,
            userText: "(the user just woke you — greet them) \(directive)",
            tools: tools,
            execute: { _, _ in "ok" },
            onToolCalled: { _, _ in }, onToolResult: { _, _ in },
            onReplyChunk: { _ in }, onStats: { _ in }
        )
        history = []
        return text
    }

    func clearHistory() async {
        history = []
    }

    /// Oldest-first trim to the token budget (chars/3 estimate — the same
    /// heuristic the on-device brain uses). Never splits a message.
    private func trimHistoryToBudget() {
        func cost(_ msg: [String: Any]) -> Int {
            var chars = 0
            if let c = msg["content"] as? String { chars += c.count }
            if let tcs = msg["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let fn = tc["function"] as? [String: Any]
                    chars += (fn?["name"] as? String)?.count ?? 0
                    chars += (fn?["arguments"] as? String)?.count ?? 0
                }
            }
            return chars / 3 + 8
        }
        var total = history.reduce(0) { $0 + cost($1) }
        while total > historyBudgetTokens, !history.isEmpty {
            total -= cost(history.removeFirst())
        }
    }

    // ── HTTP ─────────────────────────────────────────────────────────────

    private struct Usage { let prompt: Int; let cached: Int; let completion: Int }

    /// Accumulated result of one streamed chat-completions request.
    private struct StreamedTurn {
        var content = ""
        /// OpenAI streams tool calls as index-keyed deltas (id once, name
        /// once, arguments concatenated across chunks).
        var toolCalls: [Int: (id: String, name: String, args: String)] = [:]
        var usage: Usage?
    }

    /// One SSE-streamed chat-completions POST via the managed gateway.
    /// Emits complete sentences to `onSentence` AS THEY FORM in the token
    /// stream — the mouth starts on sentence one while the rest generates.
    /// `<think>` blocks (thinking-family leak) are withheld from emission.
    private func postStreaming(
        messages: [[String: Any]],
        tools: [LocalBrainTool],
        onSentence: @escaping @Sendable (String) -> Void
    ) async throws -> StreamedTurn {
        let request = try buildRequest(
            messages: messages, tools: tools, maxTokensOverride: nil, stream: true
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            var snippet = ""
            for try await line in bytes.lines {
                snippet += line
                if snippet.count > 300 { break }
            }
            throw HostedLocalBrainError.badResponse(status: status, body: String(snippet.prefix(300)))
        }

        var turn = StreamedTurn()
        var sentenceBuf = ""
        var inThink = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let usage = obj["usage"] as? [String: Any] {
                let details = usage["prompt_tokens_details"] as? [String: Any]
                turn.usage = Usage(
                    prompt: usage["prompt_tokens"] as? Int ?? 0,
                    cached: details?["cached_tokens"] as? Int ?? 0,
                    completion: usage["completion_tokens"] as? Int ?? 0
                )
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any]
            else { continue }

            if let piece = delta["content"] as? String, !piece.isEmpty {
                turn.content += piece
                sentenceBuf += piece
                // Withhold anything inside a <think>…</think> block from the
                // mouth; the closing tag drops the block from the buffer.
                if inThink {
                    if let close = sentenceBuf.range(of: "</think>") {
                        sentenceBuf = String(sentenceBuf[close.upperBound...])
                        inThink = false
                    } else { continue }
                }
                if let open = sentenceBuf.range(of: "<think>") {
                    let before = String(sentenceBuf[..<open.lowerBound])
                    for s in Self.sentences(of: before) { onSentence(s) }
                    sentenceBuf = String(sentenceBuf[open.upperBound...])
                    inThink = true
                    continue
                }
                while let sentence = Self.popCompleteSentence(&sentenceBuf) {
                    onSentence(sentence)
                }
            }
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let idx = tc["index"] as? Int ?? 0
                    var cur = turn.toolCalls[idx] ?? (id: "", name: "", args: "")
                    if let id = tc["id"] as? String { cur.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let n = fn["name"] as? String { cur.name += n }
                        if let a = fn["arguments"] as? String { cur.args += a }
                    }
                    turn.toolCalls[idx] = cur
                }
            }
        }
        // Tail without a terminal boundary is still a speakable sentence.
        if !inThink {
            let tail = sentenceBuf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { onSentence(tail) }
        }
        return turn
    }

    /// Pop the first COMPLETE sentence (terminal punctuation seen) off the
    /// buffer, or nil when none is complete yet. Streaming counterpart of
    /// `sentences(of:)`.
    static func popCompleteSentence(_ buf: inout String) -> String? {
        for (i, ch) in buf.enumerated() {
            if ch == "." || ch == "!" || ch == "?" || ch == "…" || ch == "\n" {
                let idx = buf.index(buf.startIndex, offsetBy: i + 1)
                let sentence = String(buf[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                buf = String(buf[idx...])
                return sentence.isEmpty ? Self.popCompleteSentence(&buf) : sentence
            }
        }
        return nil
    }

    /// One chat-completions POST via the managed gateway. Returns
    /// choices[0].message. Non-streaming: sim latency is dominated by the
    /// CPU machine's token rate either way; SSE streaming is a follow-up.
    /// Build the gateway request. `stream: true` adds SSE streaming with
    /// usage included in the final chunk.
    private func buildRequest(
        messages: [[String: Any]],
        tools: [LocalBrainTool],
        maxTokensOverride: Int?,
        stream: Bool
    ) throws -> URLRequest {
        guard let token = backing.authToken() else {
            throw HostedLocalBrainError.notAuthenticated
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokensOverride ?? maxTokens,
        ]
        if stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                let schema: Any
                if let json = tool.schemaJson, let data = json.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    schema = parsed
                } else {
                    schema = ["type": "object", "properties": [String: Any]()]
                }
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": schema,
                    ],
                ]
            }
        }

        guard let url = URL(string: backing.chatCompletionsUrl) else {
            throw HostedLocalBrainError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        backing.applyAuth(to: &request, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// One NON-streamed chat-completions POST (prefillPrefix's warm ping).
    private func post(
        messages: [[String: Any]],
        tools: [LocalBrainTool],
        maxTokensOverride: Int? = nil,
        onUsage: ((Usage) -> Void)? = nil
    ) async throws -> [String: Any] {
        let request = try buildRequest(
            messages: messages, tools: tools,
            maxTokensOverride: maxTokensOverride, stream: false
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw HostedLocalBrainError.badResponse(status: status, body: snippet)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { throw HostedLocalBrainError.malformedResponse }

        if let usage = json["usage"] as? [String: Any] {
            let details = usage["prompt_tokens_details"] as? [String: Any]
            onUsage?(Usage(
                prompt: usage["prompt_tokens"] as? Int ?? 0,
                cached: details?["cached_tokens"] as? Int ?? 0,
                completion: usage["completion_tokens"] as? Int ?? 0
            ))
        }
        return message
    }

    // ── Model-family shaping ─────────────────────────────────────────────

    /// Qwen3 chat templates default to thinking mode; the on-device profiles
    /// disable it with a "/no_think" system suffix. Mirror that here so the
    /// hosted turn behaves like the on-device turn for the same id.
    private func systemMessage(_ instructions: String) -> [String: Any] {
        let suffix = model.hasPrefix("local-qwen3") ? " /no_think" : ""
        return ["role": "system", "content": instructions + suffix]
    }

    /// Defense-in-depth for thinking-family models: a leaked
    /// `<think>…</think>` block must never reach the mouth.
    private func stripThink(_ text: String) -> String {
        guard let open = text.range(of: "<think>") else { return text }
        guard let close = text.range(of: "</think>") else {
            return String(text[..<open.lowerBound])
        }
        return String(text[..<open.lowerBound]) + String(text[close.upperBound...])
    }

    /// Sentence-boundary segments for the mouth pump (parity with the
    /// on-device brain's streaming granularity — per-sentence barge-in).
    static func sentences(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "…" || ch == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}
