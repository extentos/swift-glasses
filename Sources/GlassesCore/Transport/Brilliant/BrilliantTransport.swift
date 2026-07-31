import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(ImageIO)
import ImageIO
#endif

// The Brilliant Labs transport — the iOS half of the vendor Android shipped
// first (Principle #4).
//
// Almost nothing here is a port of Android's logic, because almost none of that
// logic is Android's: framing, chunking, reassembly, the Lua bundle, the connect
// handshake, panel geometry and display layout all live in the shared Rust core.
// What a shell owns is the socket (`CoreBluetoothBleBridge`) and the mapping
// from core callbacks onto this platform's stream types. That is the whole
// reason the vendor model puts protocol work in the core: a second platform
// costs the socket, not the protocol.
//
// PREVIEW: no Brilliant hardware has run this on either platform.

#if canImport(CoreBluetooth) && canImport(AVFAudio)

public final class BrilliantTransport: GlassesTransport, @unchecked Sendable {

    private let eventsContinuation: AsyncStream<TransportEvent>.Continuation
    public nonisolated let events: AsyncStream<TransportEvent>

    private let bridge: CoreBluetoothBleBridge
    private var core: BrilliantCore!

    /// Completed when the link reaches `.ready` — i.e. the on-device bundle is
    /// running. `.connected` is NOT enough: the device understands nothing
    /// until then.
    private let gate = ReadyGate()

    /// Resolved by the observer with the next reassembled JPEG. Same
    /// arrive-before-wait handling as `ReadyGate`: on a fast link the photo can
    /// land before the await begins, and without that the caller would hang
    /// until the timeout on a capture that already succeeded.
    private let photoGate = PhotoGate()

    private let lock = NSLock()
    private var onSelect: (@Sendable (String) -> Void)?
    private var onBack: (@Sendable () -> Void)?

    /// The element a select would act on. The device cannot traverse focus on
    /// its own — it has no swipe — so the first interactive node holds it.
    private var focusedId: String?

    /// Live `audioChunks()` readers.
    private var chunkSinks: [UUID: AsyncStream<AudioChunk>.Continuation] = [:]

    /// The BLE audio presented as an audio input, so `PlatformSttEngine` can
    /// drive it exactly as it drives the phone's microphone.
    ///
    /// Built in `init` rather than lazily: `transcriptions()` is nonisolated and
    /// a `lazy var` first touched from two threads at once initialises twice,
    /// which here would mean a recogniser subscribed to an input nothing feeds.
    private var audioInput: BleAudioInput!

    /// Reference count across `audioChunks()` readers and the recogniser, so
    /// the glasses' microphone runs while anything is listening and stops when
    /// nothing is. An app that never asks never pays for the radio.
    private var micUsers = 0

    private var sttEngine: PlatformSttEngine?
    private var sttHandle: SttEngineHandle?

    public convenience init() {
        self.init(bridge: CoreBluetoothBleBridge())
    }

    init(bridge: CoreBluetoothBleBridge) {
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = stream
        self.eventsContinuation = continuation
        self.bridge = bridge

        self.core = BrilliantCore(bridge: bridge, observer: Observer(transport: self))
        bridge.attach(core)
        self.audioInput = BleAudioInput(
            onFirstSubscribe: { [weak self] in self?.retainMic() },
            onLastUnsubscribe: { [weak self] in self?.releaseMic() }
        )
    }

    // ── Observer ─────────────────────────────────────────────────────────────

    private final class Observer: BrilliantObserver {
        private weak var transport: BrilliantTransport?
        init(transport: BrilliantTransport) { self.transport = transport }

        func onStateChanged(state: LinkState) {
            switch state {
            case .ready: transport?.gate.resolve(true)
            case .disconnected: transport?.gate.resolve(false)
            default: break
            }
        }

        func onPhoto(jpeg: Data) {
            // Hand it to whoever asked. A photo with no waiter is not an error —
            // the wearer can press the button — it just has nowhere to go.
            transport?.photoGate.resolve(jpeg)
        }

        func onAudio(pcm: Data) {
            // The completed clip. recordAudio would consume this; nothing does
            // yet, so it is deliberately dropped rather than buffered forever.
        }

        func onAudioChunk(pcm: Data) {
            transport?.deliverMicChunk(pcm)
        }

        // Both of Brilliant's inputs land on the focused element. Halo's button
        // could carry more (single/double/long are three distinct events, and
        // the four display actions do not all have a gesture), but mapping the
        // extra ones is a decision to make with hardware in hand.
        func onTap() {
            transport?.select()
        }

        func onClick(kind: ClickAction) {
            switch kind {
            case .single, .double: transport?.select()
            case .long: transport?.back()
            }
        }

        func onImu(data: Data) {}

        func onDeviceLog(line: String) {
            // Lua errors arrive here and nowhere else; losing them would make
            // an on-device failure completely invisible.
            transport?.bridgeLog("device: \(line)")
        }

        func onHandshakeFailed(reason: String) {
            transport?.bridgeLog("handshake failed: \(reason)")
            transport?.gate.resolve(false)
        }
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    public func connect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError> {
        gate.arm()
        // DeviceId is the BLE local name here ("Halo AB") — how a user picks
        // between two pairs in the same room. Nil takes the first Brilliant
        // device that answers.
        core.connect(nameFilter: deviceId)

        // The core carries no clock by design, so the timeout is ours. Generous
        // because a first connect uploads the whole bundle one BLE packet at a
        // time, and that is slow by construction.
        let ok = await gate.wait(timeoutMs: Self.connectTimeoutMs)
        if ok { return .success(()) }
        core.disconnect()
        return .failure(.noDeviceAvailable)
    }

    public func disconnect() async {
        core.disconnect()
    }

    public func shutdown() async {
        await stopStt()
        core.disconnect()
        bridge.disconnect()
        lock.lock()
        let sinks = Array(chunkSinks.values)
        chunkSinks.removeAll()
        lock.unlock()
        sinks.forEach { $0.finish() }
        eventsContinuation.finish()
    }

    // ── Display — the real path ──────────────────────────────────────────────

    public nonisolated func isDisplayCapable() -> Bool { core.device() != nil }

    public func showDisplay(
        root: DisplayNode,
        onSelect: @escaping @Sendable (String) -> Void,
        onBack: (@Sendable () -> Void)?
    ) async {
        lock.lock()
        self.onSelect = onSelect
        self.onBack = onBack
        lock.unlock()

        // Layout, panel geometry and framing all happen in the core — a shell
        // that repeated any of it would be a second place for the layout to
        // drift from Android.
        do {
            let rendered = try core.showDisplay(root: root)
            lock.lock()
            focusedId = rendered.firstInteractiveId
            lock.unlock()

            // Say what could not be drawn rather than leaving a developer to
            // wonder why their heading looks like body text.
            for note in rendered.unsupported { bridgeLog("display: \(note)") }
            if rendered.clippedPx > 0 {
                bridgeLog("display: \(rendered.clippedPx)px clipped — trees clip rather than scroll")
            }
        } catch {
            bridgeLog("display: \(error)")
        }
    }

    public func clearDisplay() async {
        do { try core.clearDisplay() } catch { bridgeLog("display: \(error)") }
    }

    // ── Audio out ────────────────────────────────────────────────────────────

    public nonisolated func sendOutgoingAudioChunk(sampleRate: Int32, pcmBytes: Data) {
        // Halo only. Frame has no speaker at all, and the core refuses rather
        // than writing into a characteristic that is not there — the
        // degradation policy's "absent capability is a safe no-op", one layer
        // down.
        do { try core.sendAudio(pcm: pcmBytes) } catch { bridgeLog("audio: \(error)") }
    }

    public func speak(text: String, config: SpeakConfig) async -> ExtentosResult<Void, AudioError> {
        // Reaching the speaker needs a phone-side TTS engine feeding
        // sendOutgoingAudioChunk. The audio path itself is built and the bound
        // that silently drops oversized packets is enforced; what is missing is
        // synthesis, so this is refused rather than silently doing nothing.
        .failure(.platformError(code: "brilliant_tts_not_wired", message: Self.notWiredTts))
    }

    public func cancelSpeak() async {}
    public func earcon(_ sound: EarconSound, volume: Float) async {}

    // ── Capture — refused, with the reason ───────────────────────────────────

    /// Take one still.
    ///
    /// Fire the request, then wait for the reassembled JPEG on the observer. The
    /// core carries no clock, so the timeout is ours, and it is generous on
    /// purpose: a still crosses BLE one MTU-sized chunk at a time, which runs to
    /// hundreds of milliseconds or seconds. That is a real latency difference
    /// from Meta rather than a fault to tune out.
    ///
    /// `config.format` is ignored because the camera emits JPEG and nothing else,
    /// and `config.dedicatedCapture` has no meaning here — there is no live
    /// stream to grab a frame from, so every still is dedicated. The returned
    /// `Photo` reports the dimensions that ARRIVED, which matters because Halo
    /// pins its own resolution and treats the request as advisory.
    ///
    /// PREVIEW: no Brilliant device has run this.
    public func capturePhoto(config: PhotoConfig) async -> ExtentosResult<Photo, CaptureError> {
        photoGate.arm()
        do {
            try core.capturePhoto(resolution: config.resolution)
        } catch {
            return .failure(.platformError(
                code: "brilliant_capture_request_failed",
                message: "The capture request could not be sent: \(error.localizedDescription)"
            ))
        }

        guard let jpeg = await photoGate.wait(timeoutMs: Self.photoTimeoutMs), !jpeg.isEmpty else {
            return .failure(.platformError(
                code: "brilliant_photo_timeout",
                message: "The glasses did not return a still within "
                    + "\(Self.photoTimeoutMs / 1000)s. A photo crosses BLE one chunk at a "
                    + "time, so a weak link or a high quality setting can exceed this; "
                    + "retry, or request a lower Resolution."
            ))
        }

        // Photo carries a uri, not bytes, so the JPEG has to land somewhere.
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = dir.appendingPathComponent("brilliant-\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: url)
        } catch {
            return .failure(.platformError(
                code: "brilliant_photo_write_failed",
                message: "The still arrived (\(jpeg.count) bytes) but could not be written: "
                    + "\(error.localizedDescription)"
            ))
        }

        // Read the dimensions from the JPEG header rather than decoding it — the
        // bytes are already the deliverable, and a full decode would cost memory
        // for nothing. Reports what ARRIVED, which matters because Halo pins its
        // own resolution and treats the requested one as advisory.
        let (width, height) = Self.jpegPixelSize(jpeg)
        return .success(Photo(
            uri: url.absoluteString,
            width: width,
            height: height,
            format: .jpeg,
            exif: nil
        ))
    }

    private static func jpegPixelSize(_ data: Data) -> (Int32, Int32) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else {
            // A still we cannot measure is still a still — the uri is the
            // deliverable. Zeroes say "unknown" rather than inventing a size.
            return (0, 0)
        }
        return (Int32(w), Int32(h))
    }

    public func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError> {
        .failure(videoStreamUnavailable()!)
    }

    /// One bounded utterance.
    ///
    /// Built ON TOP of `transcriptions(config:)` rather than beside it, which is
    /// what keeps it small: that path already builds the recogniser over the BLE
    /// audio input, and tears it down on termination. Duplicating any of it would
    /// be a second place for the audio lifecycle to drift. Mirrors Android.
    ///
    /// **The recogniser's own endpointing is the silence detection.** A
    /// `Transcript.final` IS the recogniser saying the utterance ended, so
    /// `silenceTimeoutSeconds` selects silence-bounded behaviour rather than
    /// setting an exact threshold — the same division of labour the Meta path
    /// uses, where silence bounding belongs to the platform bridge.
    ///
    /// `maxDurationSeconds` is a hard cap enforced here; with both bounds unset
    /// the capture runs to `recordHardCapMs`, which exists only so a forgotten
    /// recording cannot hold the glasses' radio for the rest of the session. A
    /// cap that fires mid-utterance still returns the best transcript so far —
    /// a partial answer beats an error the caller cannot act on.
    ///
    /// PREVIEW: no Brilliant device has run this.
    public func recordAudio(config: AudioRecordConfig) async -> ExtentosResult<AudioRecording, AudioError> {
        let startedAt = Date()
        let capMs = config.maxDurationSeconds.map { Int($0) * 1000 } ?? Self.recordHardCapMs

        let stream = transcriptions(config: TranscriptionConfig())

        // Race the recogniser against the cap. Cancelling the collector ends the
        // `for await`, which terminates the stream, which is what stops the
        // recogniser and releases the microphone — so the cap tears everything
        // down through the same path a normal endpoint does.
        let collector = Task { () -> (String, Bool) in
            var text = ""
            var saw = false
            for await t in stream {
                saw = true
                switch t {
                case .partial(let partial, _):
                    if !partial.isEmpty { text = partial }
                case .final(let final, _, _, _):
                    if !final.isEmpty { text = final }
                    return (text, saw)
                }
            }
            // Reached on cancellation (the cap) or a stream that ended without a
            // final — either way, return what was accumulated rather than losing it.
            return (text, saw)
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(capMs) * 1_000_000)
            collector.cancel()
        }
        let (best, sawAnything) = await collector.value
        deadline.cancel()

        let durationMs = Int64(Date().timeIntervalSince(startedAt) * 1000)
        if best.isEmpty && !sawAnything {
            return .failure(.platformError(
                code: "brilliant_record_no_recognizer",
                message: "recordDiscrete produced nothing: no speech recogniser could be "
                    + "reached for glasses audio. Collect audio.audioChunks() and run your own "
                    + "recogniser if this device cannot serve one."
            ))
        }
        return .success(AudioRecording(
            transcript: best,
            audioDurationMs: durationMs,
            // No raw-audio file: the mic fan-out hands out PCM live and this path
            // keeps nothing, so inventing a uri would promise a file that does
            // not exist. Collect audioChunks() if you need the bytes.
            rawAudioUri: nil
        ))
    }

    public nonisolated func videoFrames(config: VideoFrameConfig) -> AsyncStream<VideoFrame> {
        // Unreachable in practice: DefaultCameraClient's no-camera gate reads
        // `videoStreamUnavailable()` and throws CameraUnavailable before this is
        // iterated. The log stays for a caller holding the transport directly.
        bridgeLog("videoFrames: \(Self.noVideo)")
        return AsyncStream { $0.finish() }
    }

    /// The reason the stream can't serve frames. This file already identified the
    /// problem — "one that completes in SILENCE is the worst outcome: the app
    /// waits forever on something that already gave up" — and could only log it,
    /// because the transport-level AsyncStream has no error channel. Now the
    /// reason reaches the caller instead of the console.
    public nonisolated func videoStreamUnavailable() -> CaptureError? {
        .platformError(code: "brilliant_no_video", message: Self.noVideo)
    }

    // ── Microphone ───────────────────────────────────────────────────────────

    /// Live microphone audio from the glasses.
    ///
    /// This is the primitive that makes an audio-first app work on Brilliant
    /// WITHOUT changing a line of that app: `glasses.audio.audioChunks()` is a
    /// pass-through to here, so the same code that reaches a Ray-Ban over the
    /// phone's Bluetooth routing reaches a Halo over its custom GATT channel.
    /// Brilliant is the reason that distinction matters — it does not present
    /// as a system headset, so the vendorless audio path cannot see it.
    public nonisolated func audioChunks(config: AudioChunkConfig) -> AsyncStream<AudioChunk> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let id = UUID()
            lock.lock()
            chunkSinks[id] = continuation
            lock.unlock()
            retainMic()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.chunkSinks.removeValue(forKey: id)
                self.lock.unlock()
                self.releaseMic()
            }
        }
    }

    /// Transcription of the glasses' microphone.
    ///
    /// Fed from the SAME chunks `audioChunks` serves, through `BleAudioInput`,
    /// so `PlatformSttEngine` — the continuous SFSpeechRecognizer loop with its
    /// authorization handling, restart-after-final and silence endpointer —
    /// drives Brilliant with no knowledge that the audio never touched the
    /// phone's microphone.
    ///
    /// iOS needs no equivalent of Android's pipe trick here:
    /// `SFSpeechAudioBufferRecognitionRequest` has always accepted buffers, so
    /// there is no version floor on this path.
    public nonisolated func transcriptions(config: TranscriptionConfig) -> AsyncStream<Transcript> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            Task { @MainActor in
                let engine = PlatformSttEngine(
                    audioInput: self.audioInput,
                    factory: SystemSttSessionFactory()
                )
                let handle = engine.start(
                    config: config,
                    onTranscript: { continuation.yield($0) },
                    onError: { [weak self] error in
                        self?.bridgeLog("transcriptions: \(error)")
                        continuation.finish()
                    }
                )
                self.lock.lock()
                self.sttEngine = engine
                self.sttHandle = handle
                self.lock.unlock()
            }

            continuation.onTermination = { [weak self] _ in
                Task { await self?.stopStt() }
            }
        }
    }

    private func stopStt() async {
        lock.lock()
        let handle = sttHandle
        sttHandle = nil
        sttEngine = nil
        lock.unlock()
        handle?.close()
    }

    // ── Internals ────────────────────────────────────────────────────────────

    private func deliverMicChunk(_ pcm: Data) {
        lock.lock()
        let sinks = Array(chunkSinks.values)
        lock.unlock()

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for sink in sinks {
            sink.yield(AudioChunk(samples: pcm, sampleRate: Self.micSampleRateHz, timestampMs: now))
        }
        // The recogniser reads the same bytes through the audio-input seam.
        audioInput.feed(pcm16: pcm, sampleRate: Self.micSampleRateHz)
    }

    private func retainMic() {
        lock.lock()
        micUsers += 1
        let shouldStart = micUsers == 1
        lock.unlock()
        guard shouldStart else { return }
        do {
            try core.startMicrophone(sampleRateKhz: UInt8(Self.micSampleRateHz / 1000))
        } catch {
            bridgeLog("microphone: \(error)")
        }
    }

    private func releaseMic() {
        lock.lock()
        micUsers = max(0, micUsers - 1)
        let shouldStop = micUsers == 0
        lock.unlock()
        guard shouldStop else { return }
        do { try core.stopMicrophone() } catch { bridgeLog("microphone: \(error)") }
    }

    private func select() {
        lock.lock()
        let cb = onSelect
        let id = focusedId
        lock.unlock()
        if let cb, let id { cb(id) }
    }

    private func back() {
        lock.lock()
        let cb = onBack
        lock.unlock()
        cb?()
    }

    private nonisolated func bridgeLog(_ message: String) {
        bridge.log(message)
    }

    // ── Constants ────────────────────────────────────────────────────────────

    private static let connectTimeoutMs: Int = 45_000
    private static let micSampleRateHz: Int = 16_000

    private static let notWiredTts =
        "speak() is not wired on Brilliant yet. Halo has a speaker and the audio path to it "
        + "works — sendOutgoingAudioChunk streams PCM to the device — but nothing synthesises "
        + "the text on the phone side yet, and Frame has no speaker at all. Use the display, "
        + "or drive your own TTS into audio output."


    /// A still crosses BLE one MTU-sized chunk at a time. Generous rather than
    /// tight: a timeout that fires on a slow-but-working link is worse than
    /// waiting. Matches Android's PHOTO_TIMEOUT_MS.
    private static let photoTimeoutMs = 30_000

    /// Backstop for an unbounded recordDiscrete — not a timeout the caller chose.
    /// Matches Android's RECORD_HARD_CAP_MS.
    private static let recordHardCapMs = 120_000

    private static let noVideo =
        "unavailable on Brilliant — neither device has a video primitive or a codec, and "
        + "frame-by-frame bitmaps over BLE are not viable at this link speed."
}

/// One-shot connect gate.
///
/// The core reports readiness on a callback and `connect()` is `async`, so
/// something has to join the two. Single-resume is enforced rather than assumed:
/// a device that disconnects during the handshake fires both a failed handshake
/// and a disconnect, and resuming a continuation twice is a crash, not a bug you
/// get to log.
/// `ReadyGate` for a photo instead of a Bool. Same shape and the same reason:
/// the value can arrive before anyone waits.
private final class PhotoGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var settled = false
    private var pending: Data?

    func arm() {
        lock.lock()
        settled = false
        pending = nil
        continuation = nil
        lock.unlock()
    }

    func resolve(_ value: Data?) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let c = continuation
        continuation = nil
        if c == nil { pending = value }
        lock.unlock()
        c?.resume(returning: value)
    }

    func wait(timeoutMs: Int) async -> Data? {
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            if !Task.isCancelled { self.resolve(nil) }
        }
        defer { timeout.cancel() }

        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            lock.lock()
            if let value = pending {
                pending = nil
                lock.unlock()
                c.resume(returning: value)
                return
            }
            if settled {
                lock.unlock()
                c.resume(returning: nil)
                return
            }
            continuation = c
            lock.unlock()
        }
    }
}

private final class ReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var settled = false
    private var pending: Bool?

    func arm() {
        lock.lock()
        settled = false
        pending = nil
        continuation = nil
        lock.unlock()
    }

    func resolve(_ value: Bool) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let c = continuation
        continuation = nil
        if c == nil { pending = value }
        lock.unlock()
        c?.resume(returning: value)
    }

    func wait(timeoutMs: Int) async -> Bool {
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            if !Task.isCancelled { self.resolve(false) }
        }
        defer { timeout.cancel() }

        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            lock.lock()
            // Readiness can land before the wait begins — a fast local link
            // beats the await. Without this the caller would hang until the
            // timeout on a connection that already succeeded.
            if let value = pending {
                pending = nil
                lock.unlock()
                c.resume(returning: value)
                return
            }
            if settled {
                lock.unlock()
                c.resume(returning: false)
                return
            }
            continuation = c
            lock.unlock()
        }
    }
}

#endif
