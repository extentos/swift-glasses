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
    /// End an in-flight `captureVideo` early — the explicit stop a "stop
    /// recording" button needs, instead of cancelling the Task.
    ///
    /// Idempotent: a no-op when no capture is active. Returns once the abort is
    /// dispatched, before the platform's drain window completes; the partial
    /// clip surfaces as the in-flight `captureVideo` return value.
    func stopVideo() async

    func videoFrames(config: VideoFrameConfig) -> AsyncThrowingStream<VideoFrame, Error>

    /// The effective config the shared camera stream is currently ARMED at, or
    /// `nil` when no stream is armed. On real glasses the FIRST camera use locks
    /// quality/frameRate for the whole session (DAT 0.8 can't reconfigure a live
    /// stream) — later calls at a different config silently reuse the armed
    /// stream; this makes that lock observable. Per-frame
    /// `VideoFrame.width`/`VideoFrame.height` remains the bandwidth
    /// quality-ladder observable within the armed config.
    ///
    /// Android parity: `CameraClient.activeStreamInfo()` (gap-ledger C2).
    func activeStreamInfo() -> ActiveStreamInfo?

    /// The camera stream's ACTIVITY over time — is a stream arming, running,
    /// system-paused, or winding down. The axis orthogonal to the connection's
    /// `camera: CameraStatus`, which is HEALTH ("will a capture work?").
    ///
    /// Use this to drive work that must follow the stream rather than the link:
    /// a live relay, a recorder, a frame-processing pipeline. In particular
    /// `.paused` is a state the connection state cannot show you — DAT 0.8
    /// pauses the stream when the wearer folds the glasses or another app takes
    /// the device session, so frames stop while the connection stays perfectly
    /// healthy. Without this, an app relaying frames onward just goes quiet
    /// with no signal.
    ///
    /// Emits the current phase immediately on subscription, then only on real
    /// transitions. Pair with `activeStreamInfo()` for the config a running
    /// stream locked at.
    ///
    /// ```swift
    /// for await phase in glasses.camera.streamState() {
    ///     switch phase {
    ///     case .streaming: relay.resume()
    ///     case .paused:    relay.hold("folded or pre-empted")
    ///     case .idle:      relay.stop()
    ///     default:         break
    ///     }
    /// }
    /// ```
    ///
    /// Android parity: `CameraClient.streamState(): Flow<CameraStreamState>`.
    func streamState() -> AsyncStream<CameraStreamState>
}

public extension CameraClient {
    func capturePhoto() async -> ExtentosResult<Photo, CaptureError> {
        await capturePhoto(config: PhotoConfig())
    }
    func videoFrames() -> AsyncThrowingStream<VideoFrame, Error> {
        videoFrames(config: VideoFrameConfig())
    }

    /// Default: no observable armed stream. Transports without a shared-stream
    /// constraint surface inherit this (mirrors the Kotlin interface default).
    func activeStreamInfo() -> ActiveStreamInfo? { nil }

    /// Default: no camera stream, so permanently idle.
    func streamState() -> AsyncStream<CameraStreamState> {
        permanentlyIdleCameraStream.stream
    }
}

/// The effective config the shared warm camera stream is ARMED at (gap-ledger
/// C2, EgoFlow's observability ask). On DAT 0.8 the first camera use locks the
/// live stream's quality/frameRate for the session (the stream can't be
/// reconfigured live) — later camera calls at a different config silently reuse
/// the armed stream. This makes the lock observable: `nil` when no stream is
/// armed. Per-frame `VideoFrame.width`/`VideoFrame.height` remains the
/// bandwidth quality-ladder observable (the ladder adapts within the armed
/// config; DAT exposes no ladder events). Mirrors Kotlin `ActiveStreamInfo`.
public struct ActiveStreamInfo: Sendable, Equatable {
    public let resolution: Resolution
    public let frameRate: Int
    public init(resolution: Resolution, frameRate: Int) {
        self.resolution = resolution
        self.frameRate = frameRate
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

/// Thrown by the `CameraClient.videoFrames` stream when the connected transport has
/// no camera path at all, so no frame will ever arrive. `error` is the same typed
/// `CaptureError` that `capturePhoto` / `captureVideo` return for this transport —
/// all three camera entry points report one reason.
///
/// Before this existed the stream simply finished, instantly and silently, which
/// every reasonable consumer reads as "the glasses disconnected" rather than "this
/// transport has no camera". The transport layer's `AsyncStream` has no error
/// channel, so finishing was the only thing it could do; `DefaultCameraClient`
/// surfaces the reason on the customer-facing `AsyncThrowingStream` instead.
///
/// ```swift
/// do {
///     for try await frame in glasses.camera.videoFrames() { render(frame) }
/// } catch let e as CameraUnavailable {
///     log("no camera on this transport: \(e.message)")
/// }
/// ```
///
/// To branch BEFORE starting a stream, read `glasses.capabilities.camera`.
///
/// Mirrors Kotlin `CameraUnavailableException`. NOTE the deliberate message
/// divergence: on Android the common cause is a build omitting
/// `com.extentos:glasses-meta`, because `com.extentos:glasses` is vendorless.
/// iOS has no such split — `RealMetaTransport` ships inside `GlassesCore` — so
/// the iOS message describes the real iOS cause (no vendor transport claimed the
/// session) rather than a dependency that doesn't exist on this platform.
public struct CameraUnavailable: Error, Sendable {
    public let error: CaptureError
    public var message: String { captureErrorMessage(error: error) }
    public init(error: CaptureError) {
        self.error = error
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
    /// Wire format of the delivered frames — the iOS-native equivalent of the
    /// Kotlin `VideoFrameConfig.format` (gap-ledger C1). `.hvc1` (the default)
    /// and `.h264` deliver a decodable **compressed** still per frame (JPEG —
    /// one `UIImage(data:)` works everywhere, `VideoFrame.isCompressed == true`),
    /// matching the simulator and the photo path. `.raw` skips the encode and
    /// hands back the **raw** pre-encode pixel bytes (`isCompressed == false`)
    /// for streaming/CV pipelines that want the planes — EgoFlow's ask. iOS
    /// carries this as the existing `Codec`/`isCompressed` pair rather than a
    /// second `format` enum (Android's `jpeg|raw_yuv` maps 1:1 onto
    /// `.hvc1/.h264 → jpeg`, `.raw → raw_yuv`).
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
    /// Microsecond presentation timestamp at native DAT precision, guaranteed
    /// strictly-increasing per stream (a non-advancing source timestamp clamps
    /// to previous+1 µs). This IS the gap-ledger C3 field — iOS exposed µs
    /// natively from day one and was the parity reference Android's added
    /// `VideoFrame.timestampUs` mirrors; there is no separate `timestampMs`
    /// (the ms on Kotlin is a legacy-compat truncation, `presentationTimeUs /
    /// 1000`).
    public let presentationTimeUs: Int64
    /// `true` when `buffer` holds a decodable compressed still (JPEG — the
    /// `.hvc1`/`.h264` default), `false` when it holds the raw pre-encode pixel
    /// bytes (the `.raw` codec). The frame-level twin of Kotlin
    /// `VideoFrame.format` (gap-ledger C1).
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
