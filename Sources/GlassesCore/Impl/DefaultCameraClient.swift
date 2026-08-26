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
        await reportCapture(kind: "photo") {
            if self.transport.isCameraPaused() { return self.streamPausedDenial(op: "capture_photo") }
            return await self.transport.capturePhoto(config: config)
        }
    }

    /// Times a discrete capture and reports the outcome to telemetry.
    ///
    /// Wraps the whole body rather than instrumenting each return, because the
    /// gates exit early and those refusals are exactly the outcomes worth
    /// counting — a capture blocked by a paused camera looks identical to a
    /// broken integration from the caller's side.
    ///
    /// Reports the error VARIANT NAME only: CaptureError variants carry
    /// human-readable detail that can quote caller input, and this path feeds
    /// the analytics warehouse, not the debug log.
    /// Mirrors `reportCapture` in DefaultCameraClient.kt.
    private func reportCapture<T>(
        kind: String,
        _ block: () async -> ExtentosResult<T, CaptureError>
    ) async -> ExtentosResult<T, CaptureError> {
        let startMs = Int64(Date().timeIntervalSince1970 * 1000)
        let result = await block()
        var outcome = "success"
        var errorCode: String?
        if case .failure(let err) = result {
            outcome = "failure"
            errorCode = captureErrorCode(error: err)
        }
        await onStreamLifecycle?.onCapture(
            kind: kind,
            outcome: outcome,
            durationMs: Int64(Date().timeIntervalSince1970 * 1000) - startMs,
            errorCode: errorCode,
            source: nil,
            sizeBytes: nil
        )
        return result
    }

    func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError> {
        await reportCapture(kind: "video") {
        if self.transport.isCameraPaused() { return self.streamPausedDenial(op: "capture_video") }
        var config = config
        // Video audio respects the raw-audio gate (privacy_mode ×
        // audio_capture_enabled — the recordDiscrete/audioChunks pair;
        // listening_mode is STT-only and deliberately NOT consulted).
        // Gate closed → capture the video WITHOUT audio, never fail it.
        // Grammar + ordering are core-owned (`resolveAudioGate`).
        if config.includeAudio, let toggles = self.toggles {
            let state = toggles.state.current
            let gatingToggle = resolveAudioGate(
                privacyRaw: state.values["privacy_mode"]?.rawJsonString,
                audioEnabledRaw: state.values["audio_capture_enabled"]?.rawJsonString
            )
            if gatingToggle != nil {
                config.includeAudio = false
            }
        }
        return await self.transport.captureVideo(config: config)
        }
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

    func stopVideo() async {
        await transport.stopVideo()
    }

    func videoFrames(config: VideoFrameConfig) -> AsyncThrowingStream<VideoFrame, Error> {
        // THE no-camera gate. The transport-level stream is an AsyncStream with no
        // error channel, so a transport with no camera path can only finish —
        // indistinguishable from a disconnect to every consumer. Surface the
        // transport's OWN typed refusal here so this stream reports exactly what
        // capturePhoto and captureVideo already report. Checked before the paused
        // gate: a transport with no camera cannot have a paused one.
        // Mirrors Kotlin DefaultCameraClient's videoStreamUnavailable gate.
        if let reason = transport.videoStreamUnavailable() {
            transport.notifyCaptureDenied(
                op: "video_frames",
                reason: "camera_unavailable",
                message: captureErrorMessage(error: reason)
            )
            return AsyncThrowingStream { $0.finish(throwing: CameraUnavailable(error: reason)) }
        }
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

    // The transport fans this out (see `ShellEventObserver.cameraStreamState`)
    // rather than the client deriving it from `events`, because `events` is a
    // single-consumer AsyncStream already owned by DefaultConnectionClient.
    // `MutableState.stream` yields the current phase on subscribe, so the seed
    // is atomic — no read-then-subscribe gap to close.
    func streamState() -> AsyncStream<CameraStreamState> {
        transport.cameraStreamState.stream
    }

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
