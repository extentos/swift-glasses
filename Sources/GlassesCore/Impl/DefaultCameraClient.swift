import Foundation

// Post pure-SDK pivot: thin pass-through to the transport. No spec-driven
// stream lookup, no streamId variants, no outgoing-direction streams.
// Mirrors `android-library/.../impl/DefaultCameraClient.kt`.

final class DefaultCameraClient: CameraClient, @unchecked Sendable {
    private let transport: any GlassesTransport
    private let toggles: (any ToggleClient)?
    private let onStreamLifecycle: (any StreamLifecycleHook)?

    init(
        transport: any GlassesTransport,
        toggles: (any ToggleClient)? = nil,
        onStreamLifecycle: (any StreamLifecycleHook)? = nil
    ) {
        self.transport = transport
        self.toggles = toggles
        self.onStreamLifecycle = onStreamLifecycle
    }

    // THE single paused gate (mirrors android-library DefaultCameraClient.kt): the
    // wearer paused the camera with a temple tap; DAT has no app-callable resume, so
    // decline with an actionable error rather than fight the platform. `streamPaused`
    // is the shared-core CaptureError variant; `isCameraPaused()` reads the core's
    // single source of truth.
    func capturePhoto(config: PhotoConfig) async -> ExtentosResult<Photo, CaptureError> {
        if transport.isCameraPaused() { return streamPausedDenial(op: "capture_photo") }
        return await transport.capturePhoto(config: config)
    }

    func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError> {
        if transport.isCameraPaused() { return streamPausedDenial(op: "capture_video") }
        var config = config
        // Video audio respects the raw-audio gate (privacy_mode ×
        // audio_capture_enabled — the recordDiscrete/audioChunks pair;
        // listening_mode is STT-only and deliberately NOT consulted).
        // Gate closed → capture the video WITHOUT audio, never fail it.
        // Grammar + ordering are core-owned (`resolveAudioGate`).
        if config.includeAudio, let toggles {
            let state = toggles.state.current
            let gatingToggle = resolveAudioGate(
                privacyRaw: state.values["privacy_mode"]?.rawJsonString,
                audioEnabledRaw: state.values["audio_capture_enabled"]?.rawJsonString
            )
            if let gatingToggle {
                config.includeAudio = false
            }
        }
        return await transport.captureVideo(config: config)
    }

    /// The paused gate fired — return the typed error AND record the denial in
    /// the transport's session trace (`GlassesTransport.notifyCaptureDenied`),
    /// so the simulator event log shows WHY nothing happened. Mirrors Kotlin
    /// DefaultCameraClient.streamPausedDenial.
    private func streamPausedDenial<T>(op: String) -> ExtentosResult<T, CaptureError> {
        transport.notifyCaptureDenied(
            op: op,
            reason: "stream_paused",
            message: captureErrorMessage(error: .streamPaused)
        )
        return .failure(.streamPaused)
    }

    func videoFrames(config: VideoFrameConfig) -> AsyncThrowingStream<VideoFrame, Error> {
        // Same single paused gate. Starting live frames while paused throws
        // CameraStreamPaused so the collector can prompt a resume. A pause MID-stream
        // is not an error — the transport's frames simply stop and resume when the
        // wearer taps, which the passthrough loop below preserves.
        if transport.isCameraPaused() {
            transport.notifyCaptureDenied(
                op: "video_frames",
                reason: "stream_paused",
                message: captureErrorMessage(error: .streamPaused)
            )
            return AsyncThrowingStream { $0.finish(throwing: CameraStreamPaused()) }
        }
        let upstream = wrapVideo(transport.videoFrames(config: config), config: config)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await frame in upstream { continuation.yield(frame) }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func activeStreamInfo() -> ActiveStreamInfo? { transport.activeStreamInfo() }

    private func wrapVideo(_ stream: AsyncStream<VideoFrame>, config: VideoFrameConfig) -> AsyncStream<VideoFrame> {
        guard let hook = onStreamLifecycle else { return stream }
        let props: [String: JSONValue] = [
            "resolution": .string(resolutionWire(config.resolution)),
            "frameRate": .int(Int64(config.frameRate)),
            // C1 parity: lifecycle events carry the delivered frame format
            // ("jpeg" | "raw_yuv") so the event log matches the Kotlin side.
            "format": .string(config.codec == .raw ? "raw_yuv" : "jpeg"),
        ]
        return StreamLifecycleWrap.wrap(stream, streamType: "video_frames", props: props, hook: hook)
    }

    private func resolutionWire(_ r: Resolution) -> String {
        switch r { case .low: return "low"; case .medium: return "medium"; case .high: return "high" }
    }
}
