import Foundation
import os

// Managed realtime provider, **thin shell** over the Rust core
// (core/extentos-core/src/realtime). The resolved model id picks the vendor
// (`gpt-*` → OpenAI, `grok-*` → xAI Grok, `gemini-*` → Google Gemini Live —
// the core carries a protocol adapter per vendor). The whole vendor-agnostic
// runtime — WS protocol, session.update, the inbound demux, barge-in, the
// response-create gate, history + compaction, audio codec/framing, reconnect
// — lives in `RealtimeVoiceCore`. This file keeps only the platform-bound seams:
//   - the URLSession WebSocket (the core's `WebSocketBridge`),
//   - the audio device (mic stream → `onMicAudio`; playback via the transport),
//   - running the customer's tool bodies,
//   - the gateway auth token + the summarizer / persistent-memory HTTP,
//   - image-URI resolution, and the event projection to `AssistantEvent`.
//
// Ported from the post-hoist Kotlin shell (`impl/OpenAiAssistantProvider.kt`)
// — C3 of the iOS parity program; replaces the pre-gateway 1,134-line BYOK
// provider. Seam-for-seam parity notes: shared-context/ios-c3-shell-workorder.md.

// ── Gateway backing ──────────────────────────────────────────────────────

/// How the assistant runtime reaches the vendor realtime API — the
/// credential + endpoints for a session. One path: the Extentos managed GATEWAY on Extentos's key,
/// authed per-call. URLs + header vocabulary are core-owned
/// (realtime/gateway.rs); this struct just binds the token source.
struct AssistantBacking: Sendable {
    /// Realtime WS base URL (the core appends `?model=…`).
    let realtimeBaseWsUrl: String
    /// chat/completions URL (compaction summarizer + memory extraction).
    let chatCompletionsUrl: String
    /// `/v1/memory` URL, or nil when persistent memory is unavailable.
    let memoryUrl: String?
    /// Bearer token, resolved per call — sim gateway token (dev) or the
    /// attest JWT (beta/prod); nil = not available yet.
    let authToken: @Sendable () -> String?
    /// Account-bound project key (production attribution header). nil in
    /// dev/sim. iOS project-key bake lands with the Phase-E codegen parity.
    let projectKey: String?

    static func gateway(
        environment: ExtentosEnvironment,
        authToken: @escaping @Sendable () -> String?,
        projectKey: String? = nil
    ) -> AssistantBacking {
        AssistantBacking(
            realtimeBaseWsUrl: gatewayRealtimeUrl(env: environment),
            chatCompletionsUrl: gatewayChatCompletionsUrl(env: environment),
            memoryUrl: gatewayMemoryUrl(env: environment),
            authToken: authToken,
            projectKey: projectKey
        )
    }

    /// Apply the managed-gateway auth headers (shape + inclusion policy are
    /// core-owned — see `gateway_auth_headers`).
    func applyAuth(to request: inout URLRequest, token: String) {
        for h in gatewayAuthHeaders(token: token, projectKey: projectKey, platform: "ios") {
            request.setValue(h.value, forHTTPHeaderField: h.name)
        }
    }
}

// ── The provider ─────────────────────────────────────────────────────────

final class RealtimeCoreProvider: AssistantProviderRuntime, @unchecked Sendable {

    private let config: AssistantConfig
    private let model: String?
    private let voice: String?
    private let turnDetection: TurnDetection
    private let reasoningEffort: ReasoningEffort
    private let backing: AssistantBacking
    private let audio: any AudioClient
    private let transport: any GlassesTransport
    private let onAssistantEvent: @Sendable (AssistantEvent) -> Void
    private let onSilenceTimeout: @Sendable () -> Void
    private let glassesStateLine: (@Sendable () -> String?)?

    private let log = Logger(subsystem: "com.extentos.glasses", category: "assistant")
    private let toolsByName: [String: ToolDefinition]
    private var outgoingHiFi: Bool { transport.outgoingAudioFidelity == .hiFi }

    private var core: RealtimeVoiceCore!
    private let wsBridge: UrlSessionWsBridge
    private var audioPumpTask: Task<Void, Never>?
    private var injectTask: Task<Void, Never>?
    private var inflight: [Task<Void, Never>] = []
    private let lock = NSLock()

    init(
        config: AssistantConfig,
        model: String?,
        voice: String?,
        turnDetection: TurnDetection,
        reasoningEffort: ReasoningEffort,
        backing: AssistantBacking,
        audio: any AudioClient,
        transport: any GlassesTransport,
        onAssistantEvent: @escaping @Sendable (AssistantEvent) -> Void,
        onSilenceTimeout: @escaping @Sendable () -> Void,
        glassesStateLine: (@Sendable () -> String?)?
    ) {
        self.config = config
        self.model = model
        self.voice = voice
        self.turnDetection = turnDetection
        self.reasoningEffort = reasoningEffort
        self.backing = backing
        self.audio = audio
        self.transport = transport
        self.onAssistantEvent = onAssistantEvent
        self.onSilenceTimeout = onSilenceTimeout
        self.glassesStateLine = glassesStateLine
        self.toolsByName = Dictionary(uniqueKeysWithValues: config.tools.map { ($0.name, $0) })
        self.wsBridge = UrlSessionWsBridge()

        self.core = RealtimeVoiceCore(
            bridge: wsBridge,
            audio: AudioSinkImpl(transport: transport),
            tools: ToolSinkImpl(owner: self),
            observer: ObserverImpl(owner: self),
            glasses: GlassesSupplierImpl(line: glassesStateLine),
            compaction: CompactionSinkImpl(owner: self),
            log: OsLogSink(logger: log),
            clock: SystemClockImpl(),
            config: buildRealtimeConfig()
        )
        wsBridge.configure(core: core, backing: backing)
    }

    private func buildRealtimeConfig() -> RealtimeConfig {
        RealtimeConfig(
            outgoingHifi: outgoingHiFi,
            tools: config.tools.map {
                RealtimeToolDef(
                    name: $0.name,
                    description: $0.description,
                    schemaJson: $0.schema.map { "\($0)" },
                    blocking: $0.blocking
                )
            },
            turnDetection: turnDetection.toRealtime(),
            historyCap: UInt32(config.historyCap),
            compactionPolicy: config.historyCompaction.toRealtimePolicy(),
            withinSessionMemory: config.withinSessionMemory,
            model: model,
            voice: voice,
            instructions: config.instructions,
            reasoningEffort: reasoningEffort.wireValue,
            // Reasoning support derives inside the core from its own catalog.
            memoryAsContextItem: true,
            hasGlassesState: glassesStateLine != nil,
            includeDeviceInfoTool: config.includeDeviceInfoTool,
            deviceInfoNote: config.deviceInfoNote,
            silenceTimeoutMs: config.silenceTimeout.map { Int64($0 * 1000) },
            baseWsUrl: backing.realtimeBaseWsUrl
        )
    }

    private var memoryStore: PersistentMemoryStore {
        PersistentMemoryStore(
            memoryUrl: backing.memoryUrl,
            chatCompletionsUrl: backing.chatCompletionsUrl,
            backing: backing,
            model: config.compactionModel ?? compactionDefaultModel(),
            userId: config.memoryUserId
        )
    }

    private var persistentMemoryOn: Bool {
        config.persistentMemory && (config.memoryStore != nil || backing.memoryUrl != nil)
    }

    // ── AssistantProviderRuntime ─────────────────────────────────────────

    func start() async {
        // Agent-driven text injection: `assistant_inject` frames → a
        // synthetic user turn through the core (drives REAL model responses).
        if let sim = transport as? BrowserSimTransport {
            let frames = sim.incomingTextFrames
            injectTask = Task { [core] in
                for await frame in frames {
                    guard case let .object(obj) = frame,
                          case let .string(source)? = obj["source"], source == "assistant_inject",
                          case let .string(text)? = obj["text"] else { continue }
                    core?.injectUserTurn(text: text)
                }
            }
        }

        // Persistent memory: load + render the preamble for the core.
        if persistentMemoryOn {
            let store = memoryStore
            let cfg = config
            let core = self.core!
            Task {
                let profile = await Self.loadStoredProfile(config: cfg, store: store)
                // Render policy is core-owned (realtime/memory.rs).
                if let preamble = memoryProfileRender(profileJson: profile) {
                    core.setMemoryPreamble(preamble: preamble)
                }
            }
        }
    }

    func connect() async throws {
        // The gateway token can lag startup; wait briefly so the bridge can auth.
        guard await awaitAuthToken() != nil else {
            throw AssistantError.networkError(cause: GatewayNotReady())
        }
        // Replay only on a re-wake (history already buffered).
        let replay = !core.conversationHistory(limit: 1).isEmpty
        if let err = await core.connect(replay: replay) {
            throw AssistantError.networkError(cause: ConnectFailed(message: err))
        }
        startAudioPump()
    }

    func disconnect() async {
        audioPumpTask?.cancel()
        audioPumpTask = nil
        core.disconnect()
    }

    func stop() async {
        audioPumpTask?.cancel()
        audioPumpTask = nil
        injectTask?.cancel()
        injectTask = nil
        lock.lock()
        let tasks = inflight
        inflight.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
        core.disconnect()

        // Persistent memory: extract + merge this session's durable signal.
        if persistentMemoryOn {
            let turns = core.conversationHistory(limit: UInt32(config.historyCap))
            if !turns.isEmpty {
                let store = memoryStore
                let cfg = config
                let existing = await Self.loadStoredProfile(config: cfg, store: store)
                if let merged = await store.extractAndMerge(
                    existing: existing, turns: turns, nowIso: Self.nowIso()
                ) {
                    await Self.saveStoredProfile(config: cfg, store: store, profile: merged)
                }
            }
        }
        core.clearHistory()
    }

    func say(_ text: String) async { core.say(text: text) }
    func greet(_ prompt: String?) async {
        core.greet(prompt: prompt)
    }

    func includeImage(uri: String, prompt: String?) async {
        guard let imageUrl = await resolveImageUrl(uri) else {
            onAssistantEvent(.error(
                kind: "include_image_unsupported_uri",
                message: "includeImage: could not resolve uri (\(uri))."
            ))
            return
        }
        core.includeImage(imageUrl: imageUrl, prompt: prompt)
    }

    func sendVideoFrame(_ frame: Data, mimeType: String) async {
        core.sendVideoFrame(frame: frame, mimeType: mimeType)
    }

    func injectSystemContext(_ text: String) { core.injectSystemContext(text: text) }
    func setReasoningEffort(_ effort: ReasoningEffort) { core.setReasoningEffort(effortWire: effort.wireValue) }
    func setVoice(_ voice: String) { core.setVoice(voice: voice) }
    func setModel(_ model: String) { core.setModel(model: model) }
    func updateInstructions(_ instructions: String) { core.updateInstructions(instructions: instructions) }
    func cancelSpeak() { core.cancelSpeak() }

    // The wake chime is one ~0.5s buffer; dispatch off the caller so a
    // blocking audio write can never delay the connect that follows it.
    func playWakeSound() {
        let core = self.core!
        Task.detached { core.playWakeSound() }
    }

    // Download + decode the dashboard wake_sound_url to PCM16-LE mono at the
    // active output rate and hand it to the core. Best-effort — any failure
    // keeps the core's built-in default chime, so a wake never breaks.
    func applyWakeSound(_ url: String?) {
        guard let url, !url.isEmpty else { return }
        let rate: Int32 = outgoingHiFi ? 24_000 : 8_000
        let core = self.core!
        let logger = log
        Task.detached {
            if let pcm = await WakeSoundLoader.load(url: url, targetRate: rate), !pcm.isEmpty {
                core.setWakeSound(sampleRate: rate, pcm: pcm)
                logger.info("assistant: custom wake sound loaded (\(pcm.count) B @ \(rate) Hz)")
            } else {
                logger.warning("assistant: custom wake sound load failed — keeping default chime")
            }
        }
    }

    func conversationHistory(limit: Int) -> [Turn] {
        guard limit > 0 else { return [] }
        return core.conversationHistory(limit: UInt32(limit)).map { $0.toPublicTurn() }
    }

    func clearHistory() { core.clearHistory() }
    func appendHistory(_ turn: Turn) { core.appendHistory(turn: turn.toRealtimeTurn()) }
    func replaceHistory(_ turns: [Turn]) { core.replaceHistory(turns: turns.map { $0.toRealtimeTurn() }) }

    // ── Platform seams ───────────────────────────────────────────────────

    private func startAudioPump() {
        audioPumpTask?.cancel()
        // The core owns decimation/µ-law/framing — the shell just forwards
        // the mic chunk (capture at the transport rate; the core downsamples).
        let stream = audio.audioChunks(config: AudioChunkConfig(chunkMillis: 32, sampleRate: 8000))
        let core = self.core!
        audioPumpTask = Task {
            for await chunk in stream {
                if Task.isCancelled { break }
                core.onMicAudio(sampleRate: Int32(chunk.sampleRate), pcm: chunk.samples)
            }
        }
    }

    private func awaitAuthToken(timeoutMs: Int = 6_000, stepMs: Int = 200) async -> String? {
        var waited = 0
        while true {
            if let token = backing.authToken() { return token }
            if waited >= timeoutMs { return nil }
            try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
            waited += stepMs
        }
    }

    private func resolveImageUrl(_ uri: String) async -> String? {
        if uri.hasPrefix("data:") { return uri }
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") { return uri }
        // Local file (file: URL or plain path) → data URL. iOS has no Photos
        // helper namespace yet (ergonomics backlog) — read directly.
        let fileUrl = uri.hasPrefix("file:") ? URL(string: uri) : URL(fileURLWithPath: uri)
        guard let fileUrl, let data = try? Data(contentsOf: fileUrl) else { return nil }
        let mime: String
        switch fileUrl.pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "heic", "heif": mime = "image/heic"
        case "webp": mime = "image/webp"
        default: mime = "image/jpeg"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func loadStoredProfile(
        config: AssistantConfig, store: PersistentMemoryStore
    ) async -> String? {
        if let dev = config.memoryStore {
            return await dev.load(userId: config.memoryUserId)
        }
        return await store.load()
    }

    private static func saveStoredProfile(
        config: AssistantConfig, store: PersistentMemoryStore, profile: String
    ) async {
        if let dev = config.memoryStore {
            await dev.save(userId: config.memoryUserId, profileJson: profile)
        } else {
            _ = await store.save(profileJson: profile)
        }
    }

    private static func nowIso() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }

    fileprivate func trackInflight(_ task: Task<Void, Never>) {
        lock.lock()
        inflight.append(task)
        if inflight.count > 32 { inflight.removeFirst(inflight.count - 32) }
        lock.unlock()
    }

    // ── Core callback-interface implementations ──────────────────────────

    private final class ToolSinkImpl: RealtimeToolSink, @unchecked Sendable {
        weak var owner: RealtimeCoreProvider?
        init(owner: RealtimeCoreProvider) { self.owner = owner }

        // Only known tools reach here (the core handles unknown calls inline).
        func onToolCall(callId: String, name: String, argsJson: String) {
            guard let owner, let tool = owner.toolsByName[name] else { return }
            let core = owner.core!
            let task = Task {
                let args = JSONValue.parse(argsJson) ?? .object([:])
                let start = DispatchTime.now()
                let result: ToolResult
                do {
                    result = try await tool.body(args)
                } catch is CancellationError {
                    return
                } catch {
                    result = .err("Tool body threw: \(error)")
                }
                let durationMs = Int64((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                let (output, isError): (String, Bool)
                switch result {
                case .ok(let o): (output, isError) = (o, false)
                case .err(let m): (output, isError) = (m, true)
                }
                core.submitToolResult(
                    callId: callId, name: name, output: output,
                    isError: isError, durationMs: durationMs
                )
            }
            owner.trackInflight(task)
        }
    }

    private final class ObserverImpl: RealtimeObserver, @unchecked Sendable {
        weak var owner: RealtimeCoreProvider?
        init(owner: RealtimeCoreProvider) { self.owner = owner }

        func onEvent(event: RealtimeEvent) {
            guard let owner else { return }
            switch event {
            case .userSpoke(let transcript):
                owner.onAssistantEvent(.userSpoke(transcript: transcript))
            case .assistantSpoke(let transcript):
                owner.onAssistantEvent(.assistantSpoke(transcript: transcript))
            case .toolCalled(let name, let callId, let argsJson):
                owner.onAssistantEvent(.toolCalled(
                    name: name, args: JSONValue.parse(argsJson) ?? .object([:]), callId: callId
                ))
            case .toolResult(let callId, let name, let output, let isError, let durationMs):
                owner.onAssistantEvent(.toolResult(
                    callId: callId, name: name, output: output,
                    isError: isError, durationMs: durationMs
                ))
            case .error(let kind, let message):
                owner.onAssistantEvent(.error(kind: kind, message: message))
            case .sessionStarted(let model, let voice):
                owner.onAssistantEvent(.sessionStarted(provider: "openai", model: model, voice: voice))
            case .reconnected(let reason, let downtimeMs):
                owner.onAssistantEvent(.reconnected(
                    reason: reason == "proactive_cadence" ? .proactiveCadence : .networkDrop,
                    downtimeMs: downtimeMs
                ))
            case .sessionEnded(let reason, let message):
                owner.onAssistantEvent(.sessionEnded(
                    reason: reason == "ceiling" ? .ceiling : .error, message: message
                ))
            case .silenceTimeout:
                owner.onSilenceTimeout()
            }
        }
    }

    private final class AudioSinkImpl: RealtimeAudioSink, @unchecked Sendable {
        let transport: any GlassesTransport
        init(transport: any GlassesTransport) { self.transport = transport }
        func play(sampleRate: Int32, pcm: Data) {
            transport.sendOutgoingAudioChunk(sampleRate: sampleRate, pcmBytes: pcm)
        }
        func cancelPlayback() { transport.cancelOutgoingAudio() }
    }

    private final class GlassesSupplierImpl: GlassesStateSupplier, @unchecked Sendable {
        let line: (@Sendable () -> String?)?
        init(line: (@Sendable () -> String?)?) { self.line = line }
        func currentLine() -> String? { line?() }
    }

    private final class CompactionSinkImpl: CompactionSink, @unchecked Sendable {
        weak var owner: RealtimeCoreProvider?
        init(owner: RealtimeCoreProvider) { self.owner = owner }

        func requestSummary(turnsJson: String) {
            guard let owner else { return }
            let core = owner.core!
            let policy = owner.config.historyCompaction
            let summarizer = GatewaySummarizer(
                backing: owner.backing,
                model: owner.config.compactionModel ?? compactionDefaultModel()
            )
            let task = Task {
                let turns = Self.parseTurns(turnsJson)
                // Every outcome reports back so the core's in-flight latch
                // always resolves: success completes (submitCompacted /
                // replaceHistory — the latter clears compaction state
                // core-side), failure cancels so the NEXT trigger retries.
                if case .custom(let compact) = policy {
                    let compacted = try? await compact(turns.map { $0.toPublicTurn() })
                    if let compacted {
                        core.replaceHistory(turns: compacted.map { $0.toRealtimeTurn() })
                    } else {
                        core.cancelCompaction()
                    }
                } else {
                    if let summary = await summarizer.summarize(turns: turns) {
                        core.submitCompacted(summaryText: summary)
                    } else {
                        core.cancelCompaction()
                    }
                }
            }
            owner.trackInflight(task)
        }

        /// Parse the core's public-Turn JSON (from `request_summary`).
        static func parseTurns(_ turnsJson: String) -> [RealtimeTurn] {
            guard let data = turnsJson.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { return [] }
            return arr.compactMap { o in
                let ts = (o["timestamp_ms"] as? NSNumber)?.int64Value ?? 0
                switch o["type"] as? String {
                case "user_text":
                    return .userText(text: o["text"] as? String ?? "", timestampMs: ts)
                case "assistant_text":
                    return .assistantText(text: o["text"] as? String ?? "", timestampMs: ts)
                case "tool_call":
                    return .toolCall(
                        name: o["name"] as? String ?? "",
                        callId: o["call_id"] as? String ?? "",
                        argsJson: o["args_json"] as? String ?? "{}",
                        timestampMs: ts
                    )
                case "tool_result":
                    return .toolResult(
                        callId: o["call_id"] as? String ?? "",
                        output: o["output"] as? String ?? "",
                        timestampMs: ts
                    )
                default:
                    return nil
                }
            }
        }
    }

    private final class OsLogSink: LogSink, @unchecked Sendable {
        let logger: Logger
        init(logger: Logger) { self.logger = logger }
        func log(level: BridgeLogLevel, message: String) {
            switch level {
            case .info: logger.info("\(message, privacy: .public)")
            case .warn: logger.warning("\(message, privacy: .public)")
            }
        }
    }

    private final class SystemClockImpl: Clock, @unchecked Sendable {
        func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    }

    struct GatewayNotReady: Error {}
    struct ConnectFailed: Error { let message: String }
}

// ── URLSession WebSocket bridge ──────────────────────────────────────────

/// The core's `WebSocketBridge` over `URLSessionWebSocketTask`. The core
/// calls connect/send/close; the delegate + receive loop feed
/// onOpen/onText/onClosed/onFailure back into the core.
private final class UrlSessionWsBridge: NSObject, WebSocketBridge, URLSessionWebSocketDelegate, @unchecked Sendable {

    private weak var core: RealtimeVoiceCore?
    private var backing: AssistantBacking?
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil
    )

    func configure(core: RealtimeVoiceCore, backing: AssistantBacking) {
        self.core = core
        self.backing = backing
    }

    func connect(url: String) {
        guard let target = URL(string: url) else {
            core?.onFailure()
            return
        }
        var request = URLRequest(url: target)
        if let token = backing?.authToken() {
            backing?.applyAuth(to: &request, token: token)
        }
        let t = session.webSocketTask(with: request)
        task = t
        t.resume()
        receiveLoop(t)
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.core?.onText(text: text)
                case .data(let data):
                    // Gemini Live sends EVERY server message as a BINARY WS
                    // frame carrying UTF-8 JSON (verified live 2026-07-17 —
                    // the Node probes masked it because `ws` hands a Buffer
                    // either way). OpenAI/Grok never send binary, so decoding
                    // to the same onText path is provider-safe. Without this
                    // arm the whole Gemini handshake dies: setupComplete
                    // arrives binary, gets dropped here, and connect() times
                    // out on ready.
                    if let text = String(data: data, encoding: .utf8) {
                        self.core?.onText(text: text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop(t)
            case .failure:
                // Distinguishing drop vs clean close happens in the delegate;
                // a receive failure with no didClose is a network failure.
                if self.task != nil { self.core?.onFailure() }
            }
        }
    }

    func sendText(text: String) {
        task?.send(.string(text)) { _ in }
    }

    func sendBinary(bytes: Data) {
        task?.send(.data(bytes)) { _ in }
    }

    func close(code: Int32, reason: String) {
        let t = task
        task = nil
        t?.cancel(
            with: URLSessionWebSocketTask.CloseCode(rawValue: Int(code)) ?? .normalClosure,
            reason: reason.data(using: .utf8)
        )
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        core?.onOpen()
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        if task != nil {
            task = nil
            core?.onClosed()
        }
    }
}

// ── Gateway summarizer (thin HTTP around core-owned policy) ──────────────

/// Compaction summarizer — the prompt, transcript format, and per-model
/// parameter rules are CORE-OWNED (realtime/summarizer.rs); this is only the
/// URLSession transport around them. Returns nil on any failure (the caller
/// cancels the compaction so the next trigger retries).
struct GatewaySummarizer: Sendable {
    let backing: AssistantBacking
    let model: String

    func summarize(turns: [RealtimeTurn]) async -> String? {
        guard !turns.isEmpty, let token = backing.authToken(),
              let url = URL(string: backing.chatCompletionsUrl) else { return nil }
        let body = compactionRequestBody(model: model, turns: turns)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        backing.applyAuth(to: &request, token: token)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return chatCompletionContent(responseBody: text)
    }
}

// ── Conversions (public Turn / config ↔ core FFI types) ──────────────────

extension RealtimeTurn {
    func toPublicTurn() -> Turn {
        switch self {
        case .userText(let text, let ts): .userText(text: text, timestampMs: ts)
        case .assistantText(let text, let ts): .assistantText(text: text, timestampMs: ts)
        case .toolCall(let name, let callId, let argsJson, let ts):
            .toolInvocation(name: name, callId: callId, argsJson: argsJson, timestampMs: ts)
        case .toolResult(let callId, let output, let ts):
            .toolReturn(callId: callId, output: output, timestampMs: ts)
        }
    }
}

extension Turn {
    func toRealtimeTurn() -> RealtimeTurn {
        switch self {
        case .userText(let text, let ts): .userText(text: text, timestampMs: ts)
        case .assistantText(let text, let ts): .assistantText(text: text, timestampMs: ts)
        case .toolInvocation(let name, let callId, let argsJson, let ts):
            .toolCall(name: name, callId: callId, argsJson: argsJson, timestampMs: ts)
        case .toolReturn(let callId, let output, let ts):
            .toolResult(callId: callId, output: output, timestampMs: ts)
        }
    }
}

extension TurnDetection {
    func toRealtime() -> RealtimeTurnDetection {
        switch self {
        case .serverVad(let threshold, let prefixPaddingMs, let silenceDurationMs):
            .serverVad(
                threshold: threshold,
                prefixPaddingMs: Int32(prefixPaddingMs),
                silenceDurationMs: Int32(silenceDurationMs)
            )
        case .semanticVad: .semanticVad
        }
    }
}

extension HistoryCompaction {
    func toRealtimePolicy() -> RealtimeCompactionPolicy {
        switch self {
        case .auto: .auto
        case .dropOldest: .dropOldest
        case .custom: .custom
        case .none: .none
        }
    }
}

extension JSONValue {
    /// Parse a JSON string into a `JSONValue`, or nil on malformed input.
    static func parse(_ json: String) -> JSONValue? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
