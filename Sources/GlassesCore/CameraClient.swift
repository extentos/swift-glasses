import Foundation
#if canImport(UIKit)
import UIKit
#endif

public protocol CameraClient: Sendable {
    func capturePhoto(config: PhotoConfig) async -> ExtentosResult<Photo, CaptureError>
    func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError>
    /// Continuous live-frame stream. Throws `CameraStreamPaused` at the start if the
    /// wearer has paused the camera (temple tap) — the streaming analogue of the
    /// `CaptureError.streamPaused` that `capturePhoto`/`captureVideo` return. A pause
    /// that happens mid-stream is not an error: frames stop and resume on the next tap.
    func videoFrames(config: VideoFrameConfig) -> AsyncThrowingStream<VideoFrame, Error>
}

public extension CameraClient {
    func capturePhoto() async -> ExtentosResult<Photo, CaptureError> {
        await capturePhoto(config: PhotoConfig())
    }
    func videoFrames() -> AsyncThrowingStream<VideoFrame, Error> {
        videoFrames(config: VideoFrameConfig())
    }
}

/// Thrown by the `CameraClient.videoFrames` stream when live frames are STARTED
/// while the wearer has paused the camera with the glasses' capture button (a single
/// temple tap = pause/resume, tap-and-hold = stop). Meta's DAT has no app-callable
/// resume — catch this, prompt the wearer to tap the temple, then start again. The
/// streaming analogue of `CaptureError.streamPaused` (photo/video).
public struct CameraStreamPaused: Error, Sendable {
    public let message: String
    public init() {
        self.message = "Camera is paused — tap the right temple of your glasses to resume the camera"
    }
}

public struct PhotoConfig: Sendable {
    public var resolution: Resolution
    public var format: PhotoFormat
    /// Take a separate *dedicated* still instead of grabbing a frame off the live
    /// stream. `false` (the default) is the frame-grab: the photo IS a frame off the
    /// shared stream, so its resolution is the stream's — the reliable path (can't trip
    /// Meta's frame-stall watchdog; instant once the stream is warm; ample for AI
    /// vision). `true` fires DAT's discrete capture: a dedicated still whose resolution
    /// is set by DAT independently of the stream (typically higher, but fixed — DAT's
    /// `capturePhoto` takes no resolution argument), traded against reliability (it can
    /// intermittently stall while a stream is live). Per call.
    public var dedicatedCapture: Bool
    public init(resolution: Resolution = .medium, format: PhotoFormat = .jpeg, dedicatedCapture: Bool = false) {
        self.resolution = resolution
        self.format = format
        self.dedicatedCapture = dedicatedCapture
    }
}

public struct VideoConfig: Sendable {
    public var resolution: Resolution
    /// Hard cap on the capture length, in whole seconds. `nil` (the
    /// default, F-DF-02) means no time cap — the capture ends only on
    /// cancellation. Video has no silence-detection exit, so `nil`
    /// means "record until the handler stops it" (the
    /// `capture_video_abort` + drain path exists for exactly this).
    /// A non-nil value caps the capture at that many seconds.
    public var maxDurationSeconds: Int?
    public var format: VideoFormat
    public var includeAudio: Bool
    /// Recording frame rate. Video and live-view share one warm camera stream that
    /// can't be reconfigured live — takes effect only when this recording is the
    /// session's first camera use (mirrors the Kotlin contract).
    public var frameRate: Int
    public init(
        resolution: Resolution = .medium,
        maxDurationSeconds: Int? = nil,
        format: VideoFormat = .mp4Hevc,
        // Default TRUE (2026-07-15): a recorded video is expected to have
        // sound; silent-by-default was a DX trap (the whole audio pipeline
        // sat unexercised behind it). Opt out per-capture, and the
        // privacy/audio toggles gate it at capture time regardless.
        includeAudio: Bool = true,
        frameRate: Int = 24
    ) {
        self.resolution = resolution
        self.maxDurationSeconds = maxDurationSeconds
        self.format = format
        self.includeAudio = includeAudio
        self.frameRate = frameRate
    }
}

public struct VideoFrameConfig: Sendable {
    public var resolution: Resolution
    public var frameRate: Int
    public var codec: Codec
    public var backpressure: Backpressure
    public init(
        resolution: Resolution = .medium,
        frameRate: Int = 15,
        codec: Codec = .hvc1,
        backpressure: Backpressure = .dropOldest
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.codec = codec
        self.backpressure = backpressure
    }
}

// `Photo` + `VideoClip` → migrated to extentos-core in Phase 2.0. iOS deltas
// on the core types: `url: URL` → `uri: String?`, `Int` dimensions → `Int32`,
// and `Photo.exif: JSONValue?` → `exif: String?` (opaque serialised JSON, the
// migration-wide JSON policy). `VideoFrame` below stays native permanently —
// a hot-path binary carrier with identity equality (decision 4).

public struct VideoFrame: Sendable {
    public let buffer: Data
    public let width: Int
    public let height: Int
    public let presentationTimeUs: Int64
    public let isCompressed: Bool
    public init(buffer: Data, width: Int, height: Int, presentationTimeUs: Int64, isCompressed: Bool) {
        self.buffer = buffer
        self.width = width
        self.height = height
        self.presentationTimeUs = presentationTimeUs
        self.isCompressed = isCompressed
    }

    #if canImport(UIKit)
    public func makeUIImage() -> UIImage? {
        UIImage(data: buffer)
    }
    #endif
}

public enum Backpressure: Sendable {
    case dropOldest
    case dropNewest
    case suspend(bufferSize: Int)
}

// `Resolution`, `PhotoFormat`, `VideoFormat`, `Codec` → migrated to
// extentos-core. iOS deltas: `VideoFormat.mp4Avc` is renamed `mp4H264`, and
// `Codec` gains a `raw` case (the canonical set is the union of both platforms).
