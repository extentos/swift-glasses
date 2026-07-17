import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(AVFAudio) && os(iOS)
import AVFoundation
#endif

// In-memory, deterministic transport used by unit tests and the fast local
// dev loop. No DAT SDK, no network. Mirrors docs/mcp/TRANSPORT.md §
// LocalSimTransport — the Kotlin in-memory implementation (no DAT SDK).

public actor LocalSimTransport: GlassesTransport {
    private let eventsContinuation: AsyncStream<TransportEvent>.Continuation
    public nonisolated let events: AsyncStream<TransportEvent>

    private var currentState: GlassesState = .notRegistered
    private let mockDevice = DeviceInfo(
        id: "local_sim_rayban",
        modelName: "Meta Ray-Ban (LocalSim)",
        firmwareVersion: "sim-1.0.0",
        deviceType: .metaRayban,
        vendor: "meta",
        modelId: "rayban_meta"
    )

    // STT machinery for headless integration tests per PHASE_6_PLAN.md
    // §6.1 ("real STT, synthetic video/audio in LocalSim"). audioChunks
    // stays synthetic (no real mic), but transcriptions() spins up
    // SFSpeechRecognizer with a default audio session — no SCO routing.
    #if canImport(AVFAudio)
    private lazy var sharedAudioInput: SharedAudioInput = SharedAudioInput(
        configureSession: { try Self.configureLocalSession() },
        teardownSession: { Self.deactivateLocalSession() }
    )
    private var sttEngine: PlatformSttEngine?
    private var sttHandle: SttEngineHandle?
    #endif

    public init() {
        (self.events, self.eventsContinuation) = AsyncStream<TransportEvent>.makeStream()
    }

    // MARK: - Lifecycle

    public func connect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError> {
        let transitions: [GlassesState] = [
            .registered,
            .deviceDiscovered(deviceId: mockDevice.id),
            .connecting(deviceId: mockDevice.id),
            .active(state: .connected(device: mockDevice, camera: .ready)),
        ]
        for next in transitions {
            currentState = next
            eventsContinuation.yield(.stateChanged(state: next))
        }
        return .success(())
    }

    public func disconnect() async {
        currentState = .disconnected(cause: .userRequested)
        eventsContinuation.yield(.stateChanged(state: currentState))
    }

    public func shutdown() async {
        eventsContinuation.finish()
    }

    // MARK: - Discrete captures

    public func capturePhoto(config: PhotoConfig) async -> ExtentosResult<Photo, CaptureError> {
        guard case .active = currentState else {
            return .failure(.notConnected)
        }
        let url = URL(fileURLWithPath: "/tmp/localsim/photo-\(UUID().uuidString).jpg")
        return .success(Photo(
            uri: url.absoluteString,
            width: 1280,
            height: 720,
            format: config.format,
            exif: nil
        ))
    }

    public func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError> {
        guard case .active = currentState else {
            return .failure(.notConnected)
        }
        let url = URL(fileURLWithPath: "/tmp/localsim/video-\(UUID().uuidString).mp4")
        // Mock synthetic duration. nil maxDuration (no real cap) has no
        // meaningful mock-duration value; fall back to the prior default
        // for telemetry shape. Mirrors Android's LocalSimTransport.kt
        // `(config.maxDurationSeconds ?: 3) * 1000`.
        let mockDurationMs = Int64((config.maxDurationSeconds ?? 3) * 1000)
        return .success(VideoClip(
            uri: url.absoluteString,
            durationMs: mockDurationMs,
            format: config.format,
            width: 1280,
            height: 720
        ))
    }

    public func recordAudio(config: AudioRecordConfig) async -> ExtentosResult<AudioRecording, AudioError> {
        guard case .active = currentState else {
            return .failure(.notConnected)
        }
        // Mock synthetic duration. nil maxDuration (no real cap) has no
        // meaningful mock-duration value; fall back to the prior default
        // for telemetry shape. Mirrors Android's LocalSimTransport.kt
        // `(config.maxDurationSeconds ?: 15) * 1000`.
        let mockDurationMs = Int64((config.maxDurationSeconds ?? 15) * 1000)
        return .success(AudioRecording(
            transcript: "localsim transcript",
            audioDurationMs: mockDurationMs,
            rawAudioUri: nil
        ))
    }

    // MARK: - Streams

    public nonisolated func videoFrames(config: VideoFrameConfig) -> AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            let task = Task.detached {
                let targetFps = max(1, config.frameRate)
                let interval = UInt64(1_000_000_000 / targetFps)
                var pts: Int64 = 0
                // C1 parity (mirrors Kotlin LocalSim's `format = config.format`):
                // the synthetic placeholder frame reflects the requested wire
                // format — `.raw` → uncompressed, everything else → compressed.
                let compressed = config.codec != .raw
                while !Task.isCancelled {
                    let frame = VideoFrame(
                        buffer: Data(),
                        width: 320,
                        height: 180,
                        presentationTimeUs: pts,
                        isCompressed: compressed
                    )
                    continuation.yield(frame)
                    pts += 1_000_000 / Int64(targetFps)
                    try? await Task.sleep(nanoseconds: interval)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func audioChunks(config: AudioChunkConfig) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            let task = Task.detached {
                var ts: Int64 = 0
                let interval = UInt64(max(1, config.chunkMillis)) * 1_000_000
                while !Task.isCancelled {
                    continuation.yield(AudioChunk(samples: Data(count: 64), sampleRate: config.sampleRate, timestampMs: ts))
                    ts += Int64(config.chunkMillis)
                    try? await Task.sleep(nanoseconds: interval)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func transcriptions(config: TranscriptionConfig) -> AsyncStream<Transcript> {
        #if canImport(AVFAudio) && canImport(Speech)
        return AsyncStream { continuation in
            Task { [weak self] in
                await self?.startTranscriptions(config: config, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.stopTranscriptions() }
            }
        }
        #else
        return AsyncStream { $0.finish() }
        #endif
    }

    #if canImport(AVFAudio) && canImport(Speech)
    private static func configureLocalSession() throws {
        // Default audio session — no SCO routing per §5.6. LocalSim is
        // exercised by host devices' built-in mics, not paired BT
        // hardware.
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif
    }

    private static func deactivateLocalSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startTranscriptions(
        config: TranscriptionConfig,
        continuation: AsyncStream<Transcript>.Continuation
    ) async {
        let audioInput = sharedAudioInput
        let result: (PlatformSttEngine, SttEngineHandle)? = await MainActor.run {
            let engine = PlatformSttEngine(
                audioInput: audioInput,
                factory: SystemSttSessionFactory()
            )
            let handle = engine.start(
                config: config,
                onTranscript: { transcript in continuation.yield(transcript) },
                onError: { _ in continuation.finish() }
            )
            return (engine, handle)
        }
        if let (engine, handle) = result {
            sttEngine = engine
            sttHandle = handle
        } else {
            continuation.finish()
        }
    }

    private func stopTranscriptions() async {
        let handle = sttHandle
        sttEngine = nil
        sttHandle = nil
        await MainActor.run {
            handle?.close()
        }
    }
    #endif

    // MARK: - Output

    public func speak(text: String, config: SpeakConfig) async -> ExtentosResult<Void, AudioError> {
        guard case .active = currentState else {
            return .failure(.notConnected)
        }
        return .success(())
    }

    public func cancelSpeak() async {
        // No-op — LocalSim speak is silent, so cancel is silent too.
        // Mirrors Android's `LocalSimTransport.cancelSpeak()`.
    }

    public func earcon(_ sound: EarconSound, volume: Float) async {
        // no-op; emitted via the public event stream by AudioClient
    }

    // MARK: - Debug injection

    public func injectStateChange(_ state: GlassesState) {
        currentState = state
        eventsContinuation.yield(.stateChanged(state: state))
    }

    public func injectHardwareAlert(_ alert: HardwareAlert) {
        eventsContinuation.yield(.hardwareAlertEvent(alert: alert))
    }
}
