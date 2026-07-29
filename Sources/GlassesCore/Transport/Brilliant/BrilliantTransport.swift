import Foundation
#if canImport(AVFAudio)
import AVFAudio
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
            // Nothing requests a photo yet; a device that sends one anyway is
            // not an error, just unexpected.
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

    public func capturePhoto(config: PhotoConfig) async -> ExtentosResult<Photo, CaptureError> {
        .failure(.platformError(code: "brilliant_camera_not_wired", message: Self.notWiredCamera))
    }

    public func captureVideo(config: VideoConfig) async -> ExtentosResult<VideoClip, CaptureError> {
        .failure(.platformError(code: "brilliant_no_video", message: Self.noVideo))
    }

    public func recordAudio(config: AudioRecordConfig) async -> ExtentosResult<AudioRecording, AudioError> {
        .failure(.platformError(code: "brilliant_mic_not_wired", message: Self.notWiredRecord))
    }

    public nonisolated func videoFrames(config: VideoFrameConfig) -> AsyncStream<VideoFrame> {
        // An AsyncStream has no error channel by contract, so an unimplemented
        // stream can only complete — and one that completes in SILENCE is the
        // worst outcome: the app waits forever on something that already gave
        // up. This says so on the way out.
        bridgeLog("videoFrames: \(Self.noVideo)")
        return AsyncStream { $0.finish() }
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

    private static let notWiredRecord =
        "recordAudio() is not wired on Brilliant yet. Live microphone audio DOES work — use "
        + "audioChunks() or transcriptions(), which is what an audio-first app wants anyway; "
        + "what is missing is the discrete record-a-clip-and-hand-it-back path."

    private static let notWiredCamera =
        "capturePhoto() is not wired on Brilliant yet. Both devices have a camera and the "
        + "protocol carries photo frames, but the capture path in the on-device bundle has not "
        + "landed. Guard on glasses.capabilities.camera."

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
