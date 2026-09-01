import Foundation

#if os(iOS)
import AVFoundation

/// The **vendor-independent audio substrate** on iOS: microphone in, speaker
/// out, STT, TTS, and Bluetooth routing — expressed purely in Apple frameworks
/// (`AVAudioSession`, `AVAudioEngine`, `SFSpeechRecognizer` via
/// `PlatformSttEngine`, `AVSpeechSynthesizer`), with **no vendor SDK anywhere
/// in the path**.
///
/// This is not new behavior. It is the audio half of `MetaHardwareBridge`
/// lifted out verbatim, because that code never touched DAT: on real Ray-Bans
/// the mic and speaker are reached over Bluetooth HFP through
/// `AVAudioSession`'s `.playAndRecord` / `.voiceChat` / `.allowBluetooth`
/// configuration, exactly as they would be on any other hands-free glasses.
/// MWDAT supplies the device session, the camera and the display — never the
/// audio.
///
/// Two consumers, mirroring Android's `SystemAudioBridge`:
///  - `MetaHardwareBridge` delegates its audio surface here, so the Meta path
///    and the vendorless path run the *same* code rather than two copies that
///    drift.
///  - `SystemAudioTransport` uses it standalone — a complete voice runtime on
///    any Bluetooth smart glasses, with no vendor credentials and no
///    connection flow.
/// PUBLIC because a vendor transport can live OUTSIDE this module. Android's
/// `SystemAudioBridge` has been public for exactly this reason — `:glasses-htc`,
/// `:glasses-xr` and `:glasses-brilliant` are separate Gradle modules that
/// borrow this audio path rather than duplicating it. iOS kept it internal only
/// because every transport used to live inside GlassesCore; HTC VIVE Eagle is
/// the first that cannot (its vendor binary has no licence permitting
/// redistribution, so it ships as a separate package). Widening this is a
/// parity fix, not a new seam: the alternative was a second copy of ~577 lines
/// of audio-session handling, which is the drift this class exists to prevent.
///
/// Only the members an out-of-module transport actually needs are public; the
/// rest stays internal.
public final class SystemAudioBridge: @unchecked Sendable {

    private let lock = NSLock()
    private var core: RealMetaCore?
    private var corePtr: RealMetaCore? {
        lock.lock(); defer { lock.unlock() }
        return core
    }

    let sharedAudioInput: SharedAudioInput
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegateBox()

    private var audioSessionActive: Bool = false
    private var audioRouteObserver: NSObjectProtocol?

    private var outgoingAudioEngine: AVAudioEngine?
    private var outgoingAudioPlayer: AVAudioPlayerNode?
    private var outgoingAudioFormat: AVAudioFormat?
    private var outgoingAudioSampleRate: Double = 0

    private var sttEngine: PlatformSttEngine?
    private var sttHandle: SttEngineHandle?

    public init() {
        // Capture-then-bind — see MetaHardwareBridge.init for the rationale:
        // SharedAudioInput must flip `audioSessionActive` for the R12
        // route-change gating without retaining this bridge.
        let holder = AudioFlagHolder()
        self.sharedAudioInput = SharedAudioInput(
            configureSession: { [holder] in
                try Self.configureAudioSession()
                holder.set(true)
            },
            teardownSession: { [holder] in
                Self.deactivateAudioSession()
                holder.set(false)
            }
        )
        holder.attach { [weak self] active in
            guard let self else { return }
            self.lock.lock()
            self.audioSessionActive = active
            self.lock.unlock()
        }
    }

    public func attachCore(_ core: RealMetaCore) {
        lock.lock()
        self.core = core
        lock.unlock()
    }

    /// Release the outgoing engine, the STT session and the route observer.
    /// Idempotent.
    public func teardown() {
        stopRouteObserver()
        let handle = takeSttHandle()
        handle?.close()
        releaseOutgoingAudio()
    }

    public func startRouteObserver() {
        lock.lock()
        let already = audioRouteObserver != nil
        lock.unlock()
        if already { return }
        wireAudioRoute()
    }

    public func stopRouteObserver() {
        lock.lock()
        let observer = audioRouteObserver
        audioRouteObserver = nil
        lock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func takeSttHandle() -> SttEngineHandle? {
        lock.lock(); defer { lock.unlock() }
        let h = sttHandle
        sttHandle = nil
        sttEngine = nil
        return h
    }

    func recordAudio(requestId: String, config: AudioRecordConfigWire) {
        Task { [weak self] in
            guard let self else { return }
            let customerConfig = AudioRecordConfig(
                maxDurationSeconds: config.maxDurationSeconds.map(Int.init),
                silenceTimeoutSeconds: Int(config.silenceTimeoutSeconds ?? 2),
                quality: config.quality
            )
            let session = AudioCaptureSession(
                audioInput: self.sharedAudioInput,
                config: customerConfig
            )
            switch await session.run() {
            case .success(let recording):
                self.corePtr?.onAudioRecorded(
                    requestId: requestId,
                    recording: recording,
                    error: nil
                )
            case .failure(let err):
                self.corePtr?.onAudioRecorded(
                    requestId: requestId,
                    recording: nil,
                    error: BridgeError(
                        code: "record_audio_failed",
                        message: Self.audioErrorMessage(err)
                    )
                )
            }
        }
    }

    func startSttSession(requestId: String, config: SttConfigWire) {
        let customerConfig = TranscriptionConfig(
            language: config.language,
            partial: config.partial
        )
        let audioInput = sharedAudioInput
        Task { @MainActor [weak self] in
            guard let self else { return }
            let engine = PlatformSttEngine(
                audioInput: audioInput,
                factory: SystemSttSessionFactory()
            )
            let handle = engine.start(
                config: customerConfig,
                onTranscript: { [weak self] transcript in
                    self?.corePtr?.onTranscript(
                        source: .appleStt,
                        transcript: transcript
                    )
                },
                onError: { [weak self] error in
                    self?.corePtr?.onTransportError(
                        error: SttErrorMapper.map(error)
                    )
                }
            )
            self.lock.lock()
            self.sttEngine = engine
            self.sttHandle = handle
            self.lock.unlock()
            self.corePtr?.onSttStarted(requestId: requestId, error: nil)
        }
    }

    func stopSttSession() {
        let handle = takeSttHandle()
        Task { @MainActor in handle?.close() }
    }

    func speak(requestId: String, text: String, config: SpeakConfigWire) {
        let utterance = AVSpeechUtterance(string: text)
        if let voice = config.voice, let explicit = AVSpeechSynthesisVoice(identifier: voice) {
            utterance.voice = explicit
        } else {
            // Voice rung 1 (doc 14 §2.4; Kokoro is rung 2): the bare
            // language lookup returns the COMPACT robot voice unless the
            // user changed system defaults. "System voice" now means the
            // best NEURAL system voice the device has installed
            // (premium > enhanced > default) — zero dependencies, still
            // fully offline, and downloadable voices upgrade it for free.
            utterance.voice = Self.bestInstalledVoice(language: "en-US")
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = max(0.0, min(1.0, AVSpeechUtteranceDefaultSpeechRate * Float(config.rate)))
        utterance.pitchMultiplier = max(0.5, min(2.0, 1.0 + Float(config.pitch)))
        utterance.volume = max(0.0, min(1.0, Float(config.volume)))

        if config.waitForCompletion {
            // Per-utterance continuation slot — see SpeechDelegateBox.
            // The delegate resumes the continuation on didFinish /
            // didCancel; we forward to `on_speak_completed` from there.
            Task { [weak self, weak speechSynthesizer, weak speechDelegate] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    guard let speechDelegate, let speechSynthesizer else {
                        cont.resume(); return
                    }
                    speechDelegate.register(utterance, continuation: cont)
                    speechSynthesizer.delegate = speechDelegate
                    speechSynthesizer.speak(utterance)
                }
                self?.corePtr?.onSpeakCompleted(requestId: requestId, error: nil)
            }
        } else {
            speechSynthesizer.speak(utterance)
            // Fire-and-forget — symmetry with Android: emit completion
            // immediately. The core forwards `Ok` to the customer without
            // awaiting.
            corePtr?.onSpeakCompleted(requestId: requestId, error: nil)
        }
    }

    func cancelSpeak() {
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    /// Best installed voice for the language: premium > enhanced > default
    /// quality, exact language match over prefix match, identifier order as
    /// the deterministic tiebreak. Cached after first resolution (the voice
    /// inventory doesn't change mid-session) and noted once for
    /// diagnosability.
    private static let voiceLock = NSLock()
    nonisolated(unsafe) private static var voiceCache: [String: AVSpeechSynthesisVoice] = [:]
    static func bestInstalledVoice(language: String) -> AVSpeechSynthesisVoice? {
        voiceLock.lock()
        defer { voiceLock.unlock() }
        if let hit = voiceCache[language] { return hit }
        let prefix = language.prefix(2)
        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int, String) {
            let quality: Int
            switch v.quality {
            case .premium: quality = 2
            case .enhanced: quality = 1
            default: quality = 0
            }
            return (quality, v.language == language ? 1 : 0, v.identifier)
        }
        let picked = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .max { rank($0) < rank($1) }
        if let picked {
            let quality = picked.quality == .premium ? "premium"
                : picked.quality == .enhanced ? "enhanced" : "default"
            WakeLedger.shared.note("tts: voice \(picked.name) (\(quality))")
            voiceCache[language] = picked
        }
        return picked
    }

    public func earcon(sound: EarconSound, volume: Float) {
        // No bundled earcon assets in Phase 2A; the existing iOS shell
        // used the system "Tink" sound as a placeholder. Preserved.
        AudioServicesPlaySystemSound(1057) // Tink
    }

    // ── Outgoing audio (Phase 4 S0.M.1) ──────────────────────────────────
    //
    // Phase 4's AssistantProvider streams TTS PCM chunks here via
    // RealMetaTransport.sendOutgoingAudioChunk. AVAudioEngine +
    // AVAudioPlayerNode buffer FIFO; mainMixerNode handles rate conversion
    // to the output device. AVAudioSession `.playAndRecord` + `.voiceChat`
    // mode + `.allowBluetooth` routes through HFP/SCO when a BT headset
    // (Ray-Bans) is paired. Mirrors the Android AudioTrack path in
    // MetaHardwareBridge.kt:825-906; ordering preserved by
    // AVAudioPlayerNode's internal FIFO and the bridge lock around
    // engine state.
    //
    // Sample-rate contract: caller passes i16 LE PCM at `sampleRate`. If
    // the provider's wire format is mulaw (Phase 4 OpenAI Realtime with
    // `audio/pcmu`), the provider decodes mulaw → i16 PCM BEFORE calling
    // — keeps this layer format-agnostic and matches the Android +
    // BrowserSim contract.
    public func playOutgoingAudioChunk(sampleRate: Int32, pcmBytes: Data) {
        if pcmBytes.isEmpty { return }

        lock.lock()
        let engine = outgoingAudioEngine
        let rateChanged = outgoingAudioSampleRate != Double(sampleRate)
        lock.unlock()

        // A non-nil engine can be silently DEAD: an AVAudioSession
        // deactivation (SharedAudioInput tears the session down whenever
        // the last mic consumer unsubscribes — routine during post-sleep
        // dormancy, where only the wake-STT restart cycle touches the
        // session) stops the engine, and AVAudioPlayerNode then swallows
        // scheduled buffers without any error. Same-rate chunks never
        // triggered a rebuild, so after sleep→re-wake every response
        // played into the void (2026-07-15 hardware finding: assistant
        // answered every wake, inaudibly). Resurrect on the next chunk —
        // the camera auto-reload lesson applied to playback.
        let engineDead = engine != nil && engine?.isRunning == false
        if engine == nil || rateChanged || engineDead {
            rebuildOutgoingAudio(sampleRate: sampleRate)
        }

        lock.lock()
        let player = outgoingAudioPlayer
        let format = outgoingAudioFormat
        lock.unlock()

        guard let player, let format,
              let buffer = Self.makePCMBuffer(format: format, pcmBytes: pcmBytes)
        else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Drop any audio queued on the outgoing player (F12 barge-in): the
    /// model sends seconds of buffered audio faster-than-realtime, and an
    /// interrupt must stop it audibly NOW, not at the buffer's natural
    /// end. `AVAudioPlayerNode.stop()` flushes its scheduled buffers;
    /// `play()` re-arms the node so subsequent chunks land on a clean
    /// queue. Mirrors Android `MetaHardwareBridge.flushOutgoingAudio()`.
    public func flushOutgoingAudio() {
        lock.lock()
        let player = outgoingAudioPlayer
        let engine = outgoingAudioEngine
        lock.unlock()
        guard let player else { return }
        player.stop()
        if engine?.isRunning == true { player.play() }
    }

    private func rebuildOutgoingAudio(sampleRate: Int32) {
        lock.lock()
        let oldEngine = outgoingAudioEngine
        let oldPlayer = outgoingAudioPlayer
        lock.unlock()

        oldPlayer?.stop()
        oldEngine?.stop()

        // Configure + activate the shared AVAudioSession. Idempotent if
        // mic-input has already activated it via SharedAudioInput. Sprint 0
        // doesn't coordinate teardown between owners — Sprint 1 lifecycle
        // work owns that.
        try? Self.configureAudioSession()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        player.play()

        // Second half of the VPIO attenuation fix; both halves are needed.
        //
        // Instantiating the Voice-Processing I/O unit attenuates playback on
        // the output scope - Apple's, unfixed since iOS 6, and invisible to the
        // API. Measured on device: 0.7 FS arriving from the gateway, 0.66 FS
        // leaving mainMixerNode, route `Speaker`, outputVolume 1.00, and barely
        // audible. Two mechanisms claw it back and they are additive - the
        // ducking configuration in `SharedAudioInput`, and re-asserting the
        // category here. Removing either is audibly worse; that was tested by
        // removing it and listening.
        //
        // ONLY on a built-in output. Re-applying the category re-applies
        // `.defaultToSpeaker`, and doing that after a route has settled turns a
        // default into an override: it pulled audio off connected Ray-Bans and
        // back onto the phone. AirPods survived it, which is what made the bug
        // look like a glasses problem rather than this line.
        //
        // After the engine is running, not in `configureAudioSession` - there
        // it lands before voice processing is enabled, so VPIO comes up
        // afterwards and re-applies the attenuation to a fix already run.
        let restore = AVAudioSession.sharedInstance()
        let port = restore.currentRoute.outputs.first?.portType
        if port == .builtInSpeaker || port == .builtInReceiver {
            try? restore.setCategory(
                restore.category, mode: restore.mode, options: restore.categoryOptions
            )
        }

        lock.lock()
        outgoingAudioEngine = engine
        outgoingAudioPlayer = player
        outgoingAudioFormat = format
        outgoingAudioSampleRate = Double(sampleRate)
        lock.unlock()
    }

    private func releaseOutgoingAudio() {
        lock.lock()
        let engine = outgoingAudioEngine
        let player = outgoingAudioPlayer
        outgoingAudioEngine = nil
        outgoingAudioPlayer = nil
        outgoingAudioFormat = nil
        outgoingAudioSampleRate = 0
        lock.unlock()

        player?.stop()
        engine?.stop()
    }

    public func hasMicPermission() -> Bool {
        let granted = AVAudioSession.sharedInstance().recordPermission == .granted
        return granted
    }

    func audioChunksStream(config: AudioChunkConfig) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            let subBox = AudioSubscriptionBox()
            let bridge = self
            var timestampMs: Int64 = 0
            let handler: (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
                let chunk = AudioChunk(
                    samples: Self.pcmData(from: buffer),
                    sampleRate: Int(buffer.format.sampleRate),
                    timestampMs: timestampMs
                )
                timestampMs += Int64(config.chunkMillis)
                continuation.yield(chunk)
            }
            // Subscribe with retry: a failed subscribe means AVAudioSession
            // activation threw (the same launch/wake race PlatformSttEngine
            // retries through). Finishing the stream here killed the
            // realtime mic pump permanently when the assistant connected
            // during the wake-time session churn (2026-07-15) — the pump's
            // `for await` ended and the assistant stayed deaf. Retry at
            // 1Hz until subscribed or the consumer goes away.
            let subscribeTask = Task { [weak bridge] in
                var attempts = 0
                while !Task.isCancelled {
                    guard let bridge else { return }
                    if let id = bridge.sharedAudioInput.subscribe(handler) {
                        await subBox.set(id)
                        if attempts > 0 {
                        }
                        // The consumer may have terminated mid-subscribe.
                        if Task.isCancelled {
                            bridge.sharedAudioInput.unsubscribe(id)
                        }
                        return
                    }
                    attempts += 1
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            continuation.onTermination = { _ in
                subscribeTask.cancel()
                Task { [bridge] in
                    if let id = await subBox.id() {
                        bridge.sharedAudioInput.unsubscribe(id)
                    }
                }
            }
        }
    }

    private func wireAudioRoute() {
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            // R12 — only forward route changes when the bridge actually owns
            // an active AVAudioSession (i.e. a mic consumer is running
            // through SharedAudioInput). Idle route changes are noise.
            self.lock.lock()
            let active = self.audioSessionActive
            self.lock.unlock()
            if !active { return }
            guard let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
            let mappedReason = Self.mapRouteChangeReason(reason)
            let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? ""
            let newRoute = Self.mapAudioPort(port)
            self.corePtr?.onAudioRouteChanged(
                newRoute: newRoute,
                reason: mappedReason
            )
        }
        lock.lock(); audioRouteObserver = observer; lock.unlock()
    }

    private static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            // `.defaultToSpeaker` is what keeps a phone-only app AUDIBLE.
            //
            // Without it, `.playAndRecord` sends output to the receiver — the
            // earpiece — so an app with no glasses attached plays the
            // assistant at conversation-held-to-your-head volume. Reported
            // from hardware as "I have to put my ear close to my mobile, even
            // with the volume all the way up", which is precisely the earpiece.
            //
            // It is the DEFAULT, not an override: the moment a headset or the
            // glasses connect, that route wins and audio follows them. So this
            // is speaker-when-alone, glasses-when-worn, with no route juggling
            // — which matters because route changes are currently reported to
            // the core and never acted on.
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true)
    }

    private static func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private static func mapRouteChangeReason(_ reason: AVAudioSession.RouteChangeReason) -> AudioRouteChangeReason {
        switch reason {
        case .newDeviceAvailable: return .newDeviceAvailable
        case .oldDeviceUnavailable: return .oldDeviceUnavailable
        case .override: return .userOverride
        case .categoryChange: return .categoryChange
        default: return .unknown
        }
    }

    private static func mapAudioPort(_ portType: String) -> AudioRoute {
        switch portType {
        case AVAudioSession.Port.bluetoothA2DP.rawValue,
             AVAudioSession.Port.bluetoothHFP.rawValue,
             AVAudioSession.Port.bluetoothLE.rawValue:
            return .bluetoothEarbuds
        case AVAudioSession.Port.headphones.rawValue:
            return .wiredEarbuds
        case AVAudioSession.Port.builtInSpeaker.rawValue:
            return .phoneSpeaker
        default:
            return .glassesSpeaker
        }
    }

    private static func audioErrorMessage(_ e: AudioError) -> String {
        switch e {
        case .notConnected: return "not_connected"
        case .permissionDenied: return "permission_denied"
        case .coexistenceBlocked: return "coexistence_blocked"
        case .disabledByUser: return "disabled_by_user"
        case .platformError(let code, let message): return "\(code): \(message)"
        }
    }

    private static func makePCMBuffer(format: AVAudioFormat, pcmBytes: Data) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(pcmBytes.count / 2)  // i16 = 2 bytes/frame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount
        pcmBytes.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.bindMemory(to: Int16.self).baseAddress,
                  let dest = buffer.int16ChannelData?[0]
            else { return }
            dest.update(from: src, count: Int(frameCount))
        }
        return buffer
    }

    private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data {
        if let channelData = buffer.int16ChannelData {
            let count = Int(buffer.frameLength) * MemoryLayout<Int16>.size
            return Data(bytes: channelData[0], count: count)
        }
        if let floatData = buffer.floatChannelData {
            // PCM16-LE mono is the AudioChunk contract (Android AudioRecord
            // parity; the Rust core parses the bytes as i16 sample pairs —
            // see on_mic_audio_sends_input_audio_append). AVAudioEngine's
            // input node delivers Float32, so convert; shipping the raw
            // float bytes fed the realtime session µ-law-encoded noise
            // (2026-07-15 hardware finding: assistant deaf after wake).
            let frames = Int(buffer.frameLength)
            var out = Data(count: frames * MemoryLayout<Int16>.size)
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self)
                let src = floatData[0]
                for i in 0..<frames {
                    let clamped = max(-1.0, min(1.0, src[i]))
                    dst[i] = Int16(clamped * 32767.0)
                }
            }
            return out
        }
        return Data()
    }
}
#endif // os(iOS)
