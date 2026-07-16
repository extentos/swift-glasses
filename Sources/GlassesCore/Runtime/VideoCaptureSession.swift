import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreMedia)
import CoreMedia
#endif

// VideoCaptureSession — drives a single `capture_video` capture using:
//
//   * MWDAT's camera frames (CMSampleBuffer) via an injected
//     `AsyncStream<CMSampleBuffer>` (the transport bridges from
//     `streamSession.videoFramePublisher` so this session stays
//     SDK-independent + testable).
//   * SharedAudioInput tap when `config.includeAudio == true`.
//
// Exit conditions, in priority order:
//   1. Task cancellation — finalize the AVAssetWriter and return
//      `.success(VideoClip)` reflecting whatever was written.
//   2. `config.maxDurationSeconds` elapsed. Skipped when
//      `maxDurationSeconds` is `nil` (the F-DF-02 default): the
//      capture has no time cap and ends only on cancellation.
//   3. Source frame stream finishes (transport closed).
//
// Cooperative cancellation is the contract: the interpreter's
// stop-condition watcher cancels the enclosing Task; this session
// catches the cancellation, calls `assetWriter.finishWriting`, and
// returns the partial. PHASE_6_PLAN.md §5.2.

#if canImport(AVFoundation) && canImport(CoreMedia)

final class VideoCaptureSession: @unchecked Sendable {
    private let videoFrames: AsyncStream<CMSampleBuffer>
    private let audioInput: (any AudioInputSubscribing)?
    private let config: VideoConfig
    private let outputURL: URL

    init(
        videoFrames: AsyncStream<CMSampleBuffer>,
        audioInput: (any AudioInputSubscribing)?,
        config: VideoConfig,
        outputURL: URL? = nil
    ) {
        self.videoFrames = videoFrames
        self.audioInput = audioInput
        self.config = config
        self.outputURL = outputURL ?? Self.makeOutputURL(format: config.format)
    }

    func run() async -> ExtentosResult<VideoClip, CaptureError> {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: Self.fileType(for: config.format))
        } catch {
            return .failure(.platformError(wrapping: VideoCaptureError.assetWriterUnavailable))
        }

        // Video input — opened lazily once we know the source format from
        // the first sample buffer. AVAssetWriter requires the input
        // descriptor to match the source's sample-format, so we can't
        // hard-code resolution / codec settings.
        let state = WriterState()
        let started = Date()

        let audioSubId = await attachAudio(writer: writer, state: state)

        // Frame ingest loop. `for await` exits cleanly on stream finish
        // OR on Task cancellation — either way we fall through to
        // finalize. Task.isCancelled is checked per-frame so a long
        // pause between frames doesn't stall the cancel path.
        for await sample in videoFrames {
            if Task.isCancelled { break }
            // Open inputs lazily on first frame when we know the format.
            if state.videoInput == nil {
                if !attachVideo(writer: writer, sampleFormat: CMSampleBufferGetFormatDescription(sample), state: state) {
                    break
                }
                writer.startWriting()
                let startPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                writer.startSession(atSourceTime: startPTS)
                state.markSessionStarted(atPTS: startPTS)
            }
            if state.videoInput?.isReadyForMoreMediaData == true {
                let ok = state.videoInput?.append(sample) ?? false
                if ok {
                    state.bumpFrameCount()
                }
            }
            // F-DF-02: `nil` maxDurationSeconds = no time cap; loop ends
            // only on cancellation or source-stream finish. Honored
            // literally — no coercion to a default.
            if let maxDurationSeconds = config.maxDurationSeconds,
               Date().timeIntervalSince(started) >= Double(maxDurationSeconds) {
                break
            }
        }

        if let id = audioSubId, let audio = audioInput {
            audio.unsubscribe(id)
        }
        await Self.finishWriting(writer: writer, state: state)

        let durationMs = Int64(Date().timeIntervalSince(started) * 1000)
        let (width, height) = state.dimensions()
        return .success(VideoClip(
            uri: outputURL.absoluteString,
            durationMs: durationMs,
            format: config.format,
            width: Int32(width),
            height: Int32(height)
        ))
    }

    // MARK: - Inputs

    private func attachVideo(
        writer: AVAssetWriter,
        sampleFormat: CMFormatDescription?,
        state: WriterState
    ) -> Bool {
        // The shared camera stream is .raw on iOS (photo frame-grab needs it, and a
        // codec swap .raw↔.hvc1 collapses the WARP channel — dogfood). .raw frames are
        // decoded pixel buffers, so ENCODE to HEVC/H.264 here rather than passthrough
        // (which assumed HEVC-encoded input). Dimensions come from the source format.
        let dims = sampleFormat.flatMap { CMVideoFormatDescriptionGetDimensions($0) }
        let width = dims.map { Int($0.width) } ?? 504
        let height = dims.map { Int($0.height) } ?? 896
        let codec: AVVideoCodecType = (config.format == .mp4H264) ? .h264 : .hevc
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        state.setDimensions(width: width, height: height)
        state.videoInput = input
        return true
    }

    private func attachAudio(writer: AVAssetWriter, state: WriterState) async -> UUID? {
        guard config.includeAudio, let audio = audioInput else { return nil }

        // Subscribe FIRST (spins the shared engine up if needed), then read
        // the live format. The track must be declared EAGERLY — inputs
        // cannot be added after `startWriting()`, so the previous
        // lazy-attach-on-first-audio-buffer raced the first video frame and
        // silently lost the track whenever video won.
        let id = audio.subscribe { [weak state] buffer, when in
            state?.handleAudioBuffer(buffer, when: when)
        }
        guard let id else {
            return nil
        }
        guard let format = audio.currentFormat() else {
            audio.unsubscribe(id)
            return nil
        }
        // AAC, not LPCM passthrough: the MP4 muxer rejects LPCM tracks
        // (`canAdd` returned false and audio silently vanished — the
        // default format is .mp4Hevc). The writer transcodes the incoming
        // LPCM buffers; AAC is valid in both .mp4 and .mov.
        // Bitrate: the legal AAC range depends on sample rate + channels.
        // Probed empirically for 16 kHz mono (2026-07-15): 48 kbps is the
        // encoder's MAXIMUM — 56/64 fail with AVFoundation -11861 on first
        // append, which fails the WHOLE writer (build 62 hardware trail);
        // omitting the key defaults to a stingy 13 kbps (audible artifacts,
        // build 63 clip analysis). 48 kbps/channel = the encode ceiling for
        // the glasses mic; also legal at the sim/local 24/48 kHz rates.
        // Per-channel key so the value stays legal if a future source is
        // stereo.
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRatePerChannelKey: 48_000,
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            audio.unsubscribe(id)
            return nil
        }
        writer.add(input)
        state.setAudio(input: input, format: format)
        return id
    }

    // MARK: - Helpers

    private static func fileType(for format: VideoFormat) -> AVFileType {
        switch format {
        case .mov: return .mov
        case .mp4Hevc, .mp4H264: return .mp4
        }
    }

    private static func makeOutputURL(format: VideoFormat) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let ext: String
        switch format {
        case .mov: ext = "mov"
        case .mp4Hevc, .mp4H264: ext = "mp4"
        }
        return dir.appendingPathComponent("extentos-video-\(UUID().uuidString).\(ext)")
    }

    private static func finishWriting(writer: AVAssetWriter, state: WriterState) async {
        state.markInputsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                cont.resume()
            }
        }
    }
}

/// Per-session AVAssetWriter input bookkeeping. Audio + video tap
/// callbacks run on different threads; the lock keeps writer mutations
/// serial.
private final class WriterState: @unchecked Sendable {
    private let lock = NSLock()
    var videoInput: AVAssetWriterInput?
    var audioInput: AVAssetWriterInput?
    private var width: Int = 0
    private var height: Int = 0
    private var frameCount: Int = 0
    private var audioSourceFormat: AVAudioFormat?
    private var cmAudioFormat: CMFormatDescription?
    // Timebase bridge: DAT camera PTS and AVAudioEngine sampleTime share no
    // epoch. The writer session starts at the first video frame's PTS; the
    // first post-session audio buffer is anchored at (wall-clock elapsed
    // since session start) into that timeline, and later buffers advance by
    // sampleTime deltas.
    private var sessionStartPTS: CMTime?
    private var sessionStartWall: Date?
    private var audioAnchorSampleTime: Int64?
    private var audioAnchorPTS: CMTime?
    private var audioAppended: Int = 0
    private var audioDroppedPreSession: Int = 0

    func setDimensions(width: Int, height: Int) {
        lock.lock(); self.width = width; self.height = height; lock.unlock()
    }

    func dimensions() -> (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (width, height)
    }

    func bumpFrameCount() {
        lock.lock(); frameCount += 1; lock.unlock()
    }

    func setAudio(input: AVAssetWriterInput, format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        audioInput = input
        audioSourceFormat = format
        // The writer is fed Int16 interleaved mono PCM that WE convert —
        // handing CoreMedia the engine's own (non-interleaved Float32)
        // AudioBufferList via SetDataBufferFromAudioBufferList failed for
        // every buffer on hardware (appended=0, build 60). Plain bytes
        // through a block buffer are deterministic.
        cmAudioFormat = WriterState.makeInt16FormatDescription(sampleRate: format.sampleRate)
    }

    func markSessionStarted(atPTS pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        sessionStartPTS = pts
        sessionStartWall = Date()
    }

    func audioStats() -> (appended: Int, droppedPreSession: Int) {
        lock.lock(); defer { lock.unlock() }
        return (audioAppended, audioDroppedPreSession)
    }

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let input = audioInput, let cmFormat = cmAudioFormat else { return }
        // Samples can only join the timeline once the writer session exists
        // (it opens on the first video frame).
        guard let startPTS = sessionStartPTS, let startWall = sessionStartWall else {
            audioDroppedPreSession += 1
            return
        }
        guard input.isReadyForMoreMediaData else { return }
        let sampleRate = audioSourceFormat?.sampleRate ?? 16_000
        let pts: CMTime
        if let anchorSample = audioAnchorSampleTime, let anchorPTS = audioAnchorPTS {
            let deltaSamples = when.isSampleTimeValid ? when.sampleTime - anchorSample : Int64(0)
            pts = CMTimeAdd(anchorPTS, CMTime(value: deltaSamples, timescale: CMTimeScale(sampleRate)))
        } else {
            let elapsed = Date().timeIntervalSince(startWall)
            let anchor = CMTimeAdd(
                startPTS,
                CMTime(seconds: elapsed, preferredTimescale: CMTimeScale(sampleRate))
            )
            audioAnchorSampleTime = when.isSampleTimeValid ? when.sampleTime : 0
            audioAnchorPTS = anchor
            pts = anchor
        }
        guard let sample = WriterState.makeAudioSampleBuffer(buffer: buffer, format: cmFormat, pts: pts, sampleRate: sampleRate) else {
            return
        }
        if input.append(sample) {
            audioAppended += 1
        }
    }

    func frameCountValue() -> Int {
        lock.lock(); defer { lock.unlock() }
        return frameCount
    }

    func markInputsFinished() {
        lock.lock()
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        lock.unlock()
    }

    // MARK: - Audio CMSampleBuffer plumbing

    /// Int16 interleaved mono LPCM at the mic's rate — the fixed on-the-wire
    /// shape we convert every engine buffer to before handing it to the
    /// writer (which transcodes to AAC).
    static func makeInt16FormatDescription(sampleRate: Double) -> CMFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var description: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    /// First-channel PCM16-LE bytes of the buffer (Float32 clamped+scaled,
    /// Int16 passed through) — the same conversion the realtime mic path
    /// uses in MetaHardwareBridge.pcmData.
    static func pcm16Bytes(from buffer: AVAudioPCMBuffer) -> Data? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        if let ch = buffer.int16ChannelData {
            return Data(bytes: ch[0], count: frames * MemoryLayout<Int16>.size)
        }
        if let ch = buffer.floatChannelData {
            var out = Data(count: frames * MemoryLayout<Int16>.size)
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self)
                let src = ch[0]
                for i in 0..<frames {
                    let clamped = max(-1.0, min(1.0, src[i]))
                    dst[i] = Int16(clamped * 32767.0)
                }
            }
            return out
        }
        return nil
    }

    static func makeAudioSampleBuffer(
        buffer: AVAudioPCMBuffer,
        format: CMFormatDescription,
        pts: CMTime,
        sampleRate: Double
    ) -> CMSampleBuffer? {
        guard let bytes = pcm16Bytes(from: buffer) else { return nil }
        let frameCount = CMItemCount(buffer.frameLength)

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }
        let copyStatus = bytes.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = 2
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sb = sampleBuffer else { return nil }
        return sb
    }
}

enum VideoCaptureError: Error, Sendable {
    case assetWriterUnavailable
}

#endif // canImport(AVFoundation) && canImport(CoreMedia)
