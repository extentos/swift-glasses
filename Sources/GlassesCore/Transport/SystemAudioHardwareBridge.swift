import Foundation

#if os(iOS)

/// `HardwareBridge` over nothing but Apple's own audio stack. Swift counterpart
/// of Android's `SystemAudioHardwareBridge`.
///
/// Audio is delegated verbatim to the shared [`SystemAudioBridge`] — the same
/// object `MetaHardwareBridge` uses, so the vendorless path and the Meta path
/// are one implementation rather than two that drift.
///
/// Everything vendor-shaped is answered honestly instead of pretended:
///  - **SDK init / registration** — nothing to initialise, nobody to register
///    with; both succeed immediately so the core's connect walk proceeds.
///  - **Device session** — refused with a hard (non-`noEligibleDevice`) error.
///    The core retries `noEligibleDevice` with backoff because on real vendor
///    hardware it is transient; here it never becomes available, so a terminal
///    error lets the capture self-heal bail on its first pass instead of waiting
///    for a camera that structurally cannot appear.
///  - **Stream / photo / video** — typed failures; the transport refuses these
///    above us with an actionable message, so nothing should reach here.
///
/// Connection state comes from reachability rather than a session: `initSdk`
/// reports a synthetic audio device and the core's `apply_reachability` promotes
/// to `Active(Connected)` once registration settles.
final class SystemAudioHardwareBridge: HardwareBridge, @unchecked Sendable {

    /// The shared, vendor-independent audio substrate.
    let audio = SystemAudioBridge()

    private let lock = NSLock()
    private var core: RealMetaCore?
    private var corePtr: RealMetaCore? {
        lock.lock(); defer { lock.unlock() }
        return core
    }

    func attachCore(_ core: RealMetaCore) {
        lock.lock()
        self.core = core
        lock.unlock()
        audio.attachCore(core)
    }

    func teardown() {
        audio.teardown()
    }

    // MARK: - SDK lifecycle

    func initSdk(requestId: String) {
        // No SDK to initialise — that is the entire point of this transport.
        corePtr?.onSdkInitResult(requestId: requestId, error: nil)
        // Publish reachability immediately: the phone's own mic and speaker are
        // always there, so audio is always available. The core promotes to
        // Active(Connected) from this once registration settles.
        corePtr?.onDeviceReachabilityChanged(device: Self.systemAudioDevice)
    }

    // MARK: - Registration

    func startRegistration(requestId: String) {
        // No vendor account, no companion app, no pairing handshake.
        corePtr?.onRegistrationResult(requestId: requestId, outcome: .alreadyRegistered)
    }

    // MARK: - Device session (absent by construction)

    func createDeviceSession(requestId: String, deviceId: String?) {
        corePtr?.onDeviceSessionCreated(
            requestId: requestId,
            info: nil,
            error: .platformError(
                code: "system_audio_no_device_session",
                message: "The system-audio transport has no vendor device session — audio "
                    + "reaches the glasses through the OS's Bluetooth routing. Camera and "
                    + "display require a vendor transport."
            )
        )
    }

    func startDeviceSession(requestId: String) {
        corePtr?.onDeviceSessionStarted(
            requestId: requestId,
            error: .platformError(
                code: "system_audio_no_device_session",
                message: "no vendor device session on the system-audio transport"
            )
        )
    }

    func stopDeviceSession() {
        // Nothing to stop.
    }

    // MARK: - Stream session (absent by construction)

    func openStream(requestId: String, config: OpenStreamConfig) {
        corePtr?.onStreamOpened(
            requestId: requestId,
            error: BridgeError(
                code: "system_audio_no_camera",
                message: "no camera stream on the system-audio transport"
            )
        )
    }

    func closeStream() {
        // Nothing to close.
    }

    // MARK: - Discrete captures

    func capturePhoto(requestId: String, format: PhotoFormat, frameGrab: Bool) {
        corePtr?.onPhotoCaptured(requestId: requestId, photo: nil, error: Self.cameraAbsent)
    }

    func captureVideo(requestId: String, config: VideoCaptureConfig) {
        corePtr?.onVideoCaptured(requestId: requestId, video: nil, error: Self.cameraAbsent)
    }

    func abortVideoCapture(requestId: String) {
        corePtr?.onVideoCaptured(requestId: requestId, video: nil, error: Self.cameraAbsent)
    }

    /// Real: the mic is the phone's own, routed to Bluetooth when available.
    func recordAudio(requestId: String, config: AudioRecordConfigWire) {
        audio.recordAudio(requestId: requestId, config: config)
    }

    // MARK: - STT / output — all real

    func startSttSession(requestId: String, config: SttConfigWire) {
        audio.startSttSession(requestId: requestId, config: config)
    }

    func stopSttSession() { audio.stopSttSession() }

    func speak(requestId: String, text: String, config: SpeakConfigWire) {
        audio.speak(requestId: requestId, text: text, config: config)
    }

    func cancelSpeak() { audio.cancelSpeak() }

    func earcon(sound: EarconSound, volume: Float) { audio.earcon(sound: sound, volume: volume) }

    // MARK: - Observers

    func startHardwareObservers() {
        // Only the audio-route observer applies. Thermal / call-state / app
        // lifecycle are phone-level and orthogonal to this transport's job;
        // they stay with the vendor bridge that already owns them.
        audio.startRouteObserver()
    }

    func stopHardwareObservers() {
        audio.stopRouteObserver()
    }

    func hasMicPermission() -> Bool { audio.hasMicPermission() }

    // MARK: - Constants

    private static let cameraAbsent = BridgeError(
        code: "system_audio_no_camera",
        message: "no camera on the system-audio transport"
    )

    /// The synthetic device standing for "whatever the OS routed". Vendor and
    /// model are deliberately unknown — `vendor` and `modelId` are
    /// open-vocabulary strings in the core precisely so a transport can be
    /// honest about not knowing.
    private static let systemAudioDevice = DeviceInfo(
        id: "system_audio",
        modelName: "Bluetooth audio",
        firmwareVersion: "",
        deviceType: .unknown,
        vendor: SystemAudioTransport.systemAudioVendor,
        modelId: nil
    )
}

#endif // os(iOS)
