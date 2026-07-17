import Foundation
import os
import CoreGraphics
import ImageIO

private extension Logger {
    static let transport = Logger(subsystem: "com.extentos.glasses", category: "transport")
}

/// Phase 2a transport — a thin Swift shell over the Rust `BrowserSimCore`.
///
/// The protocol state machine, frame handlers, reconnect loop, capture/audio/
/// speak ops and stream sinks all live in `extentos-core` (see
/// `core/extentos-core/src/transport/`). This shell:
///
///  1. Owns the `URLSessionWebSocketTask` and pipes it through the core's
///     [`WebSocketBridge`] callback interface (§ 3b channel 2).
///  2. Bridges the core's [`TransportEventObserver`] onto an `AsyncStream`
///     that surfaces the customer-facing `events` API.
///  3. Maps the public Swift API onto the core's flat per-arg method shapes
///     (`PhotoConfig` → `(resolution, format)` etc.).
///  4. Surfaces `setSessionUrl` / `currentSessionUrl` (DebugClient rebinds the
///     running transport via these) and the MCP `/whoami` probe.
///
/// The wire protocol is byte-identical to the prior native implementation —
/// the core writes the same frames. See `docs/mcp/SIMULATOR_PROTOCOL.md` for
/// the canonical contract.
public final class BrowserSimTransport: GlassesTransport, @unchecked Sendable {

    public static let protocolVersion = 1

    private let eventsContinuation: AsyncStream<TransportEvent>.Continuation
    public nonisolated let events: AsyncStream<TransportEvent>

    private let bridge: URLSessionWebSocketBridge
    private let core: BrowserSimCore
    private let mcpWhoamiUrl: String

    // Phase 4 / S2.M.4 — raw inbound JSON-text frames from the sim
    // WebSocket. Surfaced for shell-level consumers that need to observe
    // specific frame types without going through the Rust core's typed
    // dispatch (which Phase 4 deliberately doesn't extend per
    // machine-split § NO Rust changes).
    //
    // Current consumer: `MockAssistantProvider` filters for
    // `type == "stt_transcript"` Finals to drive the agent E2E loop.
    // Without this hook the `audio.transcriptions()` Flow path doesn't
    // reach Mock — see `phase-4-sprint1-dogfood-findings.md` for the
    // root-cause investigation that motivated this addition (Android's
    // equivalent landed in commit 79b572b).
    //
    // Implementation: a per-subscriber AsyncStream is registered against
    // a continuation dictionary (mirrors `MutableState.stream`); each
    // inbound text frame is parsed once + fanned out to every subscriber.
    // Buffering policy on each per-subscriber stream is
    // `.bufferingNewest(128)` — matches Kotlin's SharedFlow drop-oldest
    // cap 128.
    private let framesLock = NSLock()
    private var frameContinuations: [UUID: AsyncStream<JSONValue>.Continuation] = [:]

    // C2 sim parity: the sim has no DAT first-armer lock, but the app-level
    // "what config is the live stream running at?" question must resolve
    // identically on both substrates. Registered at videoFrames start, removed
    // on termination. Kotlin twin: `activeVideoStreams`.
    private let videoStreamsLock = NSLock()
    private var activeVideoStreams: [String: ActiveStreamInfo] = [:]

    /// Fresh `AsyncStream<JSONValue>` of parsed inbound text frames. Each
    /// access returns an independent stream; multiple subscribers see
    /// the same fan-out emissions. Stream terminates only when the
    /// subscribing `Task` is cancelled.
    // Sim gateway token — attached by the backend to session_init /
    // session_attached for a project-bound sim session: an env="dev" attest
    // JWT that lets the OpenAI gateway provider authenticate from the sim
    // WITHOUT the device attestation a simulator cannot produce. Read
    // lazily by the managed-gateway backing at WS-open. nil before the
    // handshake completes, or on a no-project sim. Mirrors Kotlin
    // BrowserSimTransport.simGatewayToken.
    public var simGatewayToken: String? {
        framesLock.lock(); defer { framesLock.unlock() }
        return _simGatewayToken
    }
    private var _simGatewayToken: String?

    // F38 — per-device display capability for THIS sim session, resolved by
    // the backend from the session's selected device model (session frames +
    // live device_changed switches). Defaults false: never claim a screen
    // the simulated device doesn't have.
    private var _simDisplayCapable = false
    private let displaySelectHandler = HandlerBox<@Sendable (String) -> Void>()
    private let displayBackHandler = HandlerBox<@Sendable () -> Void>()
    private var displayCollectorTask: Task<Void, Never>?

    public var incomingTextFrames: AsyncStream<JSONValue> {
        AsyncStream(bufferingPolicy: .bufferingNewest(128)) { cont in
            let token = UUID()
            self.framesLock.lock()
            self.frameContinuations[token] = cont
            self.framesLock.unlock()
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.framesLock.lock()
                _ = self.frameContinuations.removeValue(forKey: token)
                self.framesLock.unlock()
            }
        }
    }

    /// Parse + fan out a raw inbound text frame. Called by the WebSocket
    /// bridge synchronously on the receive thread BEFORE handing the
    /// frame to the Rust core. Non-blocking; skips malformed JSON.
    fileprivate func emitIncomingTextFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return
        }
        // Session handshake carries the gateway token (also on re-attach
        // after a reconnect, so capture on both frame types) and the
        // device's display capability (also pushed on device_changed).
        if case let .object(obj) = parsed,
           case let .string(type)? = obj["type"] {
            if type == "session_init" || type == "session_attached",
               case let .string(token)? = obj["gateway_token"] {
                framesLock.lock()
                _simGatewayToken = token
                framesLock.unlock()
            }
            if type == "session_init" || type == "session_attached" || type == "device_changed",
               let capable = obj["display_capable"] {
                let on: Bool
                switch capable {
                case .bool(let b): on = b
                case .string(let s): on = s == "true"
                default: on = false
                }
                framesLock.lock()
                _simDisplayCapable = on
                framesLock.unlock()
            }
        }
        framesLock.lock()
        let conts = Array(frameContinuations.values)
        framesLock.unlock()
        for c in conts { c.yield(parsed) }
    }

    public init(
        initialSessionUrl: String?,
        pendingMode: Bool = false,
        deviceInstallId: String? = nil,
        mcpWhoamiUrl: String = "http://localhost:31337/whoami",
        pendingBaseUrl: String = "wss://api.extentos.com",
        hostAppPackageName: String? = nil
    ) {
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = stream
        self.eventsContinuation = continuation
        self.mcpWhoamiUrl = mcpWhoamiUrl

        let bridge = URLSessionWebSocketBridge(
            session: URLSession(configuration: .default)
        )
        self.bridge = bridge
        self.core = BrowserSimCore(
            bridge: bridge,
            events: ShellEventObserver(continuation: continuation),
            log: SwiftLogSink(),
            clock: SystemClock(),
            config: BrowserSimConfig(
                clientMetadata: ClientMetadata(
                    sdk: "extentos-glasses-core",
                    sdkVersion: "0.1.0-phase3",
                    platform: "ios"
                ),
                initialSessionUrl: initialSessionUrl,
                pendingMode: pendingMode,
                deviceInstallId: deviceInstallId,
                pendingBaseUrl: pendingBaseUrl,
                hostAppPackageName: hostAppPackageName
            )
        )
        bridge.attachCore(core)
        // Wire the raw-frame observer after self is fully initialized so
        // [weak self] capture is legal. Bridge invokes the observer on
        // its receive thread before handing the frame to the Rust core.
        bridge.attachRawTextFrameObserver { [weak self] text in
            self?.emitIncomingTextFrame(text)
        }
    }

    // MARK: - Public session URL rebinding (DebugClient hook)

    public func setSessionUrl(_ url: String?) {
        core.setSessionUrl(url: url)
    }

    public func currentSessionUrl() -> String? {
        core.currentSessionUrl()
    }

    // MARK: - GlassesTransport lifecycle

    public func connect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError> {
        // The MCP `/whoami` probe stays shell-side — the core does no network.
        let mcpInstallId = await probeMcpInstallId()
        if let err = await core.connect(mcpInstallId: mcpInstallId) {
            return .failure(err)
        }
        return .success(())
    }

    public func disconnect() async {
        core.disconnect()
    }

    public func shutdown() async {
        core.shutdown()
        eventsContinuation.finish()
    }

    // MARK: - Transport ops

    public func capturePhoto(config: PhotoConfig) async -> ExtentosResult<Photo, CaptureError> {
        switch await core.capturePhoto(resolution: config.resolution, format: config.format, dedicatedCapture: config.dedicatedCapture) {
        case .ok(let photo): return .success(photo)
        case .err(let err): return .failure(err)
        }
    }

    public func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError> {
        // F-R4-05: caller cancellation → core.abortCaptureVideo() + bounded
        // drain. Mirrors Android `captureVideo` (which uses `scope.async` +
        // `NonCancellable` + `withTimeoutOrNull(VIDEO_DRAIN_TIMEOUT_MS +
        // 1_000)`). The detached Task hosts the in-flight core call so it
        // survives caller cancellation — the core needs to keep running to
        // produce the partial result after the abort frame round-trips. The
        // bounded wait protects against a hung core never resolving.
        let work = Task<CaptureVideoResult, Never> { [core] in
            await core.captureVideo(
                maxDurationSeconds: config.maxDurationSeconds.map(Int32.init),
                includeAudio: config.includeAudio,
                format: config.format
            )
        }

        // Drive the await + cancellation hook. `Task<T, Never>.value` is not
        // itself a cancellation point — caller cancellation fires `onCancel`
        // synchronously but the body keeps awaiting `work.value` until either
        // (a) work resolves naturally (happy path or post-abort partial), or
        // (b) the bounded-drain helper resolves `nil` because work timed out.
        let bounded: CaptureVideoResult? = await withTaskCancellationHandler {
            await Self.awaitWithBound(work, timeoutMs: nil)
        } onCancel: {
            // Caller cancelled. Fire the abort frame (top-level Task survives
            // caller cancellation) and bound the wait — the body re-enters
            // `awaitWithBound` via the cancellation flag below.
            Task { [core] in
                await core.abortCaptureVideo()
            }
        }

        if let bounded = bounded {
            switch bounded {
            case .ok(let clip): return .success(clip)
            case .err(let err): return .failure(err)
            }
        }

        // The body returned nil only if we ran the bounded wait and it timed
        // out. Re-await once with the explicit bound so a hung core doesn't
        // pin caller's Task forever.
        let drained = await Self.awaitWithBound(
            work,
            timeoutMs: UInt64(Self.videoDrainTimeoutMs + 1_000)
        )
        if let drained = drained {
            switch drained {
            case .ok(let clip): return .success(clip)
            case .err(let err): return .failure(err)
            }
        }
        return .failure(.platformError(wrapping: BrowserSimError.timeout))
    }

    public func recordAudio(config: AudioRecordConfig) async -> ExtentosResult<AudioRecording, AudioError> {
        switch await core.recordAudio(
            maxDurationSeconds: config.maxDurationSeconds.map(Int32.init),
            silenceTimeoutSeconds: Double(config.silenceTimeoutSeconds),
            quality: config.quality
        ) {
        case .ok(let recording): return .success(recording)
        case .err(let err): return .failure(err)
        }
    }

    public func speak(text: String, config: SpeakConfig) async -> ExtentosResult<Void, AudioError> {
        switch await core.speak(
            text: text,
            voice: config.voice,
            rate: Double(config.rate),
            pitch: Double(config.pitch),
            volume: Double(config.volume),
            waitForCompletion: config.waitForCompletion
        ) {
        case .ok: return .success(())
        case .err(let err): return .failure(err)
        }
    }

    public func cancelSpeak() async {
        core.cancelSpeak()
    }

    public func earcon(_ sound: EarconSound, volume: Float) async {
        core.earcon(sound: sound, volume: volume)
    }

    /// Phase 3 / Track 2 audio-OUT — pump TTS PCM out to the simulator
    /// browser via the hub's binary relay (F1). See the Rust core's
    /// `send_outgoing_audio_chunk` doc for the wire shape: one
    /// `{type:"tts_audio_chunk", timestamp_ms, sample_rate}` JSON
    /// frame + one binary PCM frame, paired by hub-relay ordering.
    ///
    /// Sync (no `async`) — the Rust core's method writes both frames
    /// and returns; the shell's `SpeakAudioSink.onChunk` callback is
    /// also sync (uniffi callback interface), so the call shape lines
    /// up end-to-end without trampolining through a Task.
    public func sendOutgoingAudioChunk(sampleRate: Int32, pcmBytes: Data) {
        core.sendOutgoingAudioChunk(sampleRate: sampleRate, pcmBytes: pcmBytes)
    }

    // The simulator plays the assistant voice through the browser's WebAudio
    // graph (SimulatorClient.playTtsAudioChunk), which has no Bluetooth
    // narrowband limit — so we request full-band 24 kHz PCM from OpenAI rather
    // than the 8 kHz µ-law the real HFP/SCO glasses link is capped at.
    public var outgoingAudioFidelity: OutgoingAudioFidelity { .hiFi }

    // MARK: - Streams

    public nonisolated func videoFrames(config: VideoFrameConfig) -> AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            // C1 sim parity: the browser's frame source is JPEG. `.raw` decodes
            // it to planar I420 (same BT.601 coefficients as the Kotlin sim, so
            // raw bytes match byte-for-byte across platforms) — the CONTRACT is
            // identical to hardware, which serves raw natively; only the
            // conversion direction differs. A frame that fails to decode is
            // dropped (matches the hardware raw path skipping an unreadable
            // buffer). Every other codec keeps the JPEG passthrough.
            let rawRequested = config.codec == .raw
            let sink = VideoFrameAdapter { ts, w, h, data in
                if rawRequested {
                    guard let i420 = Self.jpegToI420(data) else { return }
                    continuation.yield(VideoFrame(
                        buffer: i420.bytes,
                        width: i420.width,
                        height: i420.height,
                        presentationTimeUs: ts * 1000,
                        isCompressed: false
                    ))
                } else {
                    continuation.yield(VideoFrame(
                        buffer: data,
                        width: Int(w),
                        height: Int(h),
                        presentationTimeUs: ts * 1000,
                        isCompressed: true
                    ))
                }
            }
            let streamId = self.core.startVideoStream(
                frameRate: Int32(config.frameRate),
                resolution: config.resolution,
                sink: sink
            )
            self.registerVideoStream(
                streamId,
                ActiveStreamInfo(resolution: config.resolution, frameRate: Int(config.frameRate))
            )
            continuation.onTermination = { [core = self.core, weak self] _ in
                self?.unregisterVideoStream(streamId)
                core.stopVideoStream(streamId: streamId)
            }
        }
    }

    private func registerVideoStream(_ id: String, _ info: ActiveStreamInfo) {
        videoStreamsLock.lock(); activeVideoStreams[id] = info; videoStreamsLock.unlock()
    }

    private func unregisterVideoStream(_ id: String) {
        videoStreamsLock.lock(); activeVideoStreams.removeValue(forKey: id); videoStreamsLock.unlock()
    }

    /// C2 observability: report the first armed video stream's config, `nil`
    /// when none is live. Kotlin twin: `activeStreamInfo()`.
    public nonisolated func activeStreamInfo() -> ActiveStreamInfo? {
        videoStreamsLock.lock(); defer { videoStreamsLock.unlock() }
        return activeVideoStreams.values.first
    }

    private struct I420Frame { let width: Int; let height: Int; let bytes: Data }

    /// Decode a JPEG to planar I420 (BT.601), even-cropped — the iOS sim twin of
    /// Kotlin `BrowserSimTransport.jpegToI420`, same coefficients so sim raw
    /// bytes match the Android sim byte-for-byte. `nil` on decode failure.
    private static func jpegToI420(_ jpeg: Data) -> I420Frame? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width & ~1
        let h = cg.height & ~1
        if w <= 0 || h <= 0 { return nil }
        // Draw into a known RGBA8888 buffer so pixel reads are deterministic
        // (the equivalent of Android's Bitmap.getPixels ARGB source).
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ySize = w * h
        let cSize = ySize / 4
        var out = [UInt8](repeating: 0, count: ySize + 2 * cSize)
        var uIdx = ySize
        var vIdx = ySize + cSize
        for row in 0..<h {
            for col in 0..<w {
                let p = (row * w + col) * 4
                let r = Int(rgba[p])
                let g = Int(rgba[p + 1])
                let b = Int(rgba[p + 2])
                out[row * w + col] = UInt8(clamping: ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16)
                if row % 2 == 0 && col % 2 == 0 {
                    out[uIdx] = UInt8(clamping: ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128); uIdx += 1
                    out[vIdx] = UInt8(clamping: ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128); vIdx += 1
                }
            }
        }
        return I420Frame(width: w, height: h, bytes: Data(out))
    }

    public nonisolated func audioChunks(config: AudioChunkConfig) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            let sink = AudioChunkAdapter { ts, sr, data in
                continuation.yield(AudioChunk(
                    samples: data,
                    sampleRate: Int(sr),
                    timestampMs: ts
                ))
            }
            let streamId = self.core.startAudioStream(
                chunkMillis: Int32(config.chunkMillis),
                sampleRate: Int32(config.sampleRate),
                sink: sink
            )
            continuation.onTermination = { [core = self.core] _ in
                core.stopAudioStream(streamId: streamId)
            }
        }
    }

    public nonisolated func transcriptions(config: TranscriptionConfig) -> AsyncStream<Transcript> {
        AsyncStream { continuation in
            let sink = TranscriptAdapter { transcript in
                continuation.yield(transcript)
            }
            let streamId = self.core.startTranscriptionStream(
                language: config.language,
                partial: config.partial,
                sink: sink
            )
            continuation.onTermination = { [core = self.core] _ in
                core.stopTranscriptionStream(streamId: streamId)
            }
        }
    }

    /// Enqueue an outbound runtime-event frame on the core. Buffered drop-oldest
    /// (cap 128) until the session is ready, then sent over the wire.
    public func isDisplayCapable() -> Bool {
        framesLock.lock(); defer { framesLock.unlock() }
        return _simDisplayCapable
    }

    public func showDisplay(
        root: DisplayNode,
        onSelect: @escaping @Sendable (String) -> Void,
        onBack: (@Sendable () -> Void)?
    ) async {
        // Never render on a device without a display — matches RealMeta +
        // the decided degradation policy.
        guard isDisplayCapable() else { return }
        // Latest show wins. Handlers + collector BEFORE sending so a fast
        // select can't race an unwired hook; onBack is per-show (DSP-10).
        displaySelectHandler.set(onSelect)
        displayBackHandler.set(onBack)
        ensureDisplaySelectCollector()
        // displayTreeToJson is the canonical serializer (extentos-core), so
        // the wire format can never drift from Android / the sim renderer.
        let treeJson = displayTreeToJson(root: root)
        var payload: [String: Any] = ["type": "display_show"]
        if let data = treeJson.data(using: .utf8),
           let tree = try? JSONSerialization.jsonObject(with: data) {
            payload["tree"] = tree
        } else {
            payload["treeJson"] = treeJson
        }
        sendOutbound(payload)
    }

    public func clearDisplay() async {
        // A cleared display has nothing to select or go back from.
        displaySelectHandler.set(nil)
        displayBackHandler.set(nil)
        sendOutbound(["type": "display_clear"])
    }

    private func ensureDisplaySelectCollector() {
        framesLock.lock()
        let alreadyStarted = displayCollectorTask != nil
        framesLock.unlock()
        if alreadyStarted { return }
        let frames = incomingTextFrames
        let task = Task { [displaySelectHandler, displayBackHandler] in
            for await frame in frames {
                guard case let .object(obj) = frame,
                      case let .string(type)? = obj["type"] else { continue }
                if type == "display_select", case let .string(id)? = obj["id"], !id.isEmpty {
                    displaySelectHandler.get()?(id)
                } else if type == "display_back" {
                    displayBackHandler.get()?()
                }
            }
        }
        framesLock.lock()
        displayCollectorTask = task
        framesLock.unlock()
    }

    public func cancelOutgoingAudio() {
        // F12 barge-in fix: drain the browser tab's AudioContext queue. The
        // browser handles `tts_audio_flush` by stopping every scheduled
        // source node + resetting its play clock. Without this,
        // response.cancel only stops NEW chunks — the seconds of
        // already-buffered audio keep playing.
        sendOutbound(["type": "tts_audio_flush"])
    }

    public func sendOutbound(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else { return }
        core.sendOutbound(payloadJson: string)
    }

    // The surrogate's capture-button state (the sim's mirror of the right-
    // temple tap). Same seam as RealMetaTransport: the core owns the stream
    // state machine; the shell is a pure query. Mirrors Kotlin
    // BrowserSimTransport.isCameraPaused.
    public nonisolated func isCameraPaused() -> Bool { core.isCameraPaused() }

    /// Record a shell-side capture denial in the session trace. The request
    /// never crossed the wire (the shared paused gate short-circuits in
    /// `DefaultCameraClient`), so without this frame the simulator's event log
    /// would show NOTHING for a denied capture. Severity `warn` lands it under
    /// the errors chip. Mirrors Kotlin BrowserSimTransport.notifyCaptureDenied.
    public func notifyCaptureDenied(op: String, reason: String, message: String) {
        sendOutbound([
            "type": "capture_denied",
            "op": op,
            "reason": reason,
            "message": message,
            "severity": "warn",
        ])
    }

    // MARK: - Shell-side MCP probe

    /// Best-effort GET on the MCP server's localhost bridge. Returns the
    /// `mcpInstallId` (an opaque string) or nil on any failure: timeout,
    /// non-200, parse error, missing field. Cleartext HTTP — the host app's
    /// Info.plist needs an NSAppTransportSecurity exemption for `localhost`
    /// / `127.0.0.1` for this to succeed; without it the probe fails
    /// silently and the dev falls through to the typed-code path. See
    /// shared-context/ios-auto-bind-handoff.md § App Transport Security.
    private func probeMcpInstallId() async -> String? {
        guard let url = URL(string: mcpWhoamiUrl) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let id: String? = {
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { return nil }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                guard let v = json["mcpInstallId"] as? String, !v.isEmpty else { return nil }
                return v
            }()
            Logger.transport.info("mcp probe result: \(id ?? "null", privacy: .public)")
            return id
        } catch {
            let typeName = String(describing: type(of: error))
            let message = error.localizedDescription
            Logger.transport.info(
                "mcp probe failed: \(typeName, privacy: .public) \(message, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Constants

    /// Mirrors the core's `VIDEO_DRAIN_TIMEOUT_MS`. The shell waits this + 1s
    /// after caller cancellation so a hung core doesn't pin the customer
    /// Task forever — Android's `withTimeoutOrNull(VIDEO_DRAIN_TIMEOUT_MS +
    /// 1_000)` equivalent.
    private static let videoDrainTimeoutMs: Int = 10_000

    // MARK: - Bounded await helper

    /// Awaits `work.value`, optionally with a millisecond bound. `nil`
    /// `timeoutMs` means "no bound — wait indefinitely." A non-nil bound
    /// returns `nil` if `work` hasn't resolved by the deadline; the work
    /// task continues running in the background (it's a top-level Task and
    /// not tied to caller's task tree).
    ///
    /// The race uses a one-shot latch + manual continuation because
    /// `Task<T, Never>.value` is not itself cancellation-aware and Swift's
    /// `withTaskGroup` propagates cancellation to its children, which would
    /// leak the await as the group waits for them to settle.
    private static func awaitWithBound<T: Sendable>(
        _ work: Task<T, Never>,
        timeoutMs: UInt64?
    ) async -> T? {
        guard let timeoutMs = timeoutMs else {
            return await work.value
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let latch = OnceLatch()
            Task {
                let v = await work.value
                if latch.tryComplete() {
                    cont.resume(returning: v)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                if latch.tryComplete() {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// ─── Channel-2: the URLSessionWebSocketTask-backed bridge ────────────────────

/// The [`WebSocketBridge`] implementation. The core calls `connect` /
/// `sendText` / `sendBinary` / `close` on this; the receive loop routes
/// `URLSessionWebSocketTask`'s inbound text/binary into `core.onText` /
/// `core.onBinary`, and the loop's eventual error fires `core.onClosed` /
/// `core.onFailure`.
///
/// URLSessionWebSocketTask serializes its receive callbacks per socket — the
/// receive loop's single iteration is the only inbound consumer, so wire
/// order and binary-pairing hold by construction, exactly what the core's
/// protocol state machine expects.
final class URLSessionWebSocketBridge: WebSocketBridge, @unchecked Sendable {
    private let session: URLSession
    private weak var core: BrowserSimCore?
    private let lock = NSLock()
    private var currentTask: URLSessionWebSocketTask?
    // Phase 4 / S2.M.4 — shell-level observer invoked for every inbound
    // text frame BEFORE the Rust core processes it. Used by
    // `BrowserSimTransport.incomingTextFrames` to surface raw JSON to
    // consumers (currently `MockAssistantProvider`'s inject-routing
    // path) without going through the Rust core's typed dispatch
    // (Phase 4 deliberately doesn't extend that per machine-split § NO
    // Rust changes). Set via `attachRawTextFrameObserver` once the
    // owning transport is fully initialized. Defaults to no-op; the
    // closure is called synchronously on the receive task, so it must
    // be fast + non-blocking — typical implementation is a `yield()` on
    // a `MutableSharedFlow`-style continuation.
    private var rawTextFrameObserver: (@Sendable (String) -> Void)?

    init(session: URLSession) {
        self.session = session
    }

    func attachCore(_ core: BrowserSimCore) {
        self.core = core
    }

    func attachRawTextFrameObserver(_ observer: @escaping @Sendable (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.rawTextFrameObserver = observer
    }

    private func snapshotRawTextFrameObserver() -> (@Sendable (String) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return rawTextFrameObserver
    }

    func connect(url: String) {
        let normalized = Self.toWebSocketUrl(url)
        guard let parsed = URL(string: normalized) else {
            core?.onFailure(code: "invalid_url", message: "could not parse: \(url)")
            return
        }
        let task = session.webSocketTask(with: parsed)
        // A capture_video result arrives as one ~2 MB base64 data: URI frame,
        // exceeding the 1 MB default of URLSessionWebSocketTask.maximumMessageSize
        // (which tears the socket down on receive). Sub-MB photos slip under it,
        // so only video capture regressed. Raise the receive cap for sim clips.
        task.maximumMessageSize = 64 * 1024 * 1024
        lock.lock()
        currentTask = task
        lock.unlock()
        task.resume()
        startReceiveLoop(task: task)
        // URLSessionWebSocketTask has no synchronous "open" event without a
        // session delegate. The prior iOS impl treated `resume()` as the
        // open trigger — preserve that here. If the handshake fails, the
        // receive loop's error fires `onFailure` shortly after.
        core?.onOpen()
    }

    func sendText(text: String) {
        let task = snapshotTask()
        task?.send(.string(text)) { _ in
            // Send errors surface via the receive loop; the only ones unique
            // to send are "socket already torn down," which the receive loop
            // will also detect.
        }
    }

    func sendBinary(bytes: Data) {
        let task = snapshotTask()
        task?.send(.data(bytes)) { _ in }
    }

    func close(code: Int32, reason: String) {
        lock.lock()
        let task = currentTask
        currentTask = nil
        lock.unlock()
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: Int(code)) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.data(using: .utf8))
    }

    private func snapshotTask() -> URLSessionWebSocketTask? {
        lock.lock(); defer { lock.unlock() }
        return currentTask
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        let core = self.core
        let observer = self.snapshotRawTextFrameObserver()
        Task.detached {
            while true {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        // Shell-level observer first so assistant inject
                        // routing can see the frame even if the Rust
                        // core is currently busy. Synchronous + non-
                        // blocking; observer is a `yield()` to an
                        // AsyncStream continuation in practice. Then
                        // hand to the core.
                        observer?(text)
                        core?.onText(text: text)
                    case .data(let data):
                        core?.onBinary(bytes: data)
                    @unknown default:
                        continue
                    }
                } catch {
                    let nsError = error as NSError
                    let rawCode = task.closeCode.rawValue
                    if rawCode != 0 {
                        core?.onClosed(
                            code: Int32(rawCode),
                            reason: nsError.localizedDescription
                        )
                    } else {
                        core?.onFailure(
                            code: String(describing: type(of: error)),
                            message: nsError.localizedDescription
                        )
                    }
                    return
                }
            }
        }
    }

    private static func toWebSocketUrl(_ url: String) -> String {
        if url.hasPrefix("ws://") || url.hasPrefix("wss://") { return url }
        if url.hasPrefix("http://") { return "ws://" + url.dropFirst("http://".count) }
        if url.hasPrefix("https://") { return "wss://" + url.dropFirst("https://".count) }
        return url
    }
}

// ─── Channel-3: the event observer + sink adapters + diagnostics ─────────────

/// Forwards core-emitted transport events onto the shell's `AsyncStream`.
/// The continuation's `bufferingPolicy` is drop-oldest at 256 (matching
/// Android's `MutableSharedFlow(replay=0, extraBufferCapacity=256,
/// DROP_OLDEST)`), so emission is non-blocking — the core calls this
/// synchronously after unlocking its state mutex.
final class ShellEventObserver: TransportEventObserver, @unchecked Sendable {
    private let continuation: AsyncStream<TransportEvent>.Continuation

    init(continuation: AsyncStream<TransportEvent>.Continuation) {
        self.continuation = continuation
    }

    func onEvent(event: TransportEvent) {
        continuation.yield(event)
    }
}

/// Generic per-stream sink adapter. The core delivers binary frames as plain
/// args; the shell wraps them into the native `VideoFrame` / `AudioChunk` /
/// `Transcript` types and yields onto the per-stream `AsyncStream`.
final class VideoFrameAdapter: VideoFrameSink, @unchecked Sendable {
    private let yield: @Sendable (Int64, Int32, Int32, Data) -> Void
    init(yield: @escaping @Sendable (Int64, Int32, Int32, Data) -> Void) {
        self.yield = yield
    }
    func onVideoFrame(timestampMs: Int64, width: Int32, height: Int32, data: Data) {
        yield(timestampMs, width, height, data)
    }
}

final class AudioChunkAdapter: AudioChunkSink, @unchecked Sendable {
    private let yield: @Sendable (Int64, Int32, Data) -> Void
    init(yield: @escaping @Sendable (Int64, Int32, Data) -> Void) {
        self.yield = yield
    }
    func onAudioChunk(timestampMs: Int64, sampleRate: Int32, data: Data) {
        yield(timestampMs, sampleRate, data)
    }
}

final class TranscriptAdapter: TranscriptSink, @unchecked Sendable {
    private let yield: @Sendable (Transcript) -> Void
    init(yield: @escaping @Sendable (Transcript) -> Void) {
        self.yield = yield
    }
    func onTranscript(transcript: Transcript) {
        yield(transcript)
    }
}

/// The diagnostics log the core would otherwise have sent to logcat / os_log
/// directly. Routes `info` to `Logger.info` and `warn` to `Logger.warning`.
final class SwiftLogSink: LogSink, @unchecked Sendable {
    func log(level: BridgeLogLevel, message: String) {
        switch level {
        case .info:
            Logger.transport.info("\(message, privacy: .public)")
        case .warn:
            Logger.transport.warning("\(message, privacy: .public)")
        }
    }
}

final class SystemClock: Clock, @unchecked Sendable {
    func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Internal helpers

/// Lock-protected once-latch. Used by `BrowserSimTransport.awaitWithBound`
/// to race `work.value` against a deadline without leaking the work via a
/// `withTaskGroup` cancellation cascade. Self-contained — not part of any
/// cross-actor `CheckedContinuation` race.
private final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func tryComplete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum BrowserSimError: Error, Sendable, CustomStringConvertible {
    case timeout

    var description: String {
        switch self {
        case .timeout: return "timeout"
        }
    }
}


/// Tiny thread-safe holder for the display select/back handlers.
final class HandlerBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T?) {
        lock.lock(); value = v; lock.unlock()
    }
    func get() -> T? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
