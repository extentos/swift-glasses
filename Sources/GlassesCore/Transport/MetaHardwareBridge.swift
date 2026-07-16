import Foundation

#if os(iOS)
import AVFoundation
import CoreImage
import CallKit
import UIKit
import MWDATCore
import MWDATCamera

/// The Meta DAT iOS impl of the vendor-agnostic [`HardwareBridge`]. Holds
/// the platform-glue (MWDAT SDK calls, `AVSpeechSynthesizer`,
/// `SharedAudioInput`, `PlatformSttEngine`, `AVAudioSession`, `CallKit`,
/// `UIApplication` lifecycle + thermal + audio-route observers,
/// `AVCaptureDevice` mic permission, `AVAssetWriter` via
/// `VideoCaptureSession` + `AudioCaptureSession`, temp-file I/O).
///
/// All [`HardwareBridge`] methods are sync request-style: any async/SDK
/// work runs inside an internal `Task { ... }` and reports back via
/// the attached [`RealMetaCore`]'s `on_*` completion methods (mirrors the
/// `WebSocketBridge` pattern from Phase 2a and `MetaHardwareBridge.kt` on
/// Android). The core ⟷ bridge coupling is wired by
/// [`RealMetaTransport`] at construction time via [`attachCore`].
///
/// Stream primitives ([`videoFramesStream`], [`audioChunksStream`]) bypass
/// the core entirely — the bridge owns the `Stream` + the
/// `SharedAudioInput`, so the shell's `AsyncStream<>` consumers go bridge →
/// sink → stream directly (R10: audio fan-out is shell-side by design).
final class MetaHardwareBridge: HardwareBridge, @unchecked Sendable {

    // ── State (lock-guarded) ─────────────────────────────────────────────

    private let lock = NSLock()
    private weak var core: RealMetaCore?

    private var deviceSession: MWDATCore.DeviceSession?
    private var streamSession: MWDATCamera.Stream?
    private var streamCodec: MWDATCamera.VideoCodec?
    private var appLifecycleStateStr = "launch"
    private var reachabilityReady = false
    private var deviceSessionStateToken: (any MWDATCore.AnyListenerToken)?
    private var deviceSessionErrorToken: (any MWDATCore.AnyListenerToken)?
    private var streamSessionStateToken: (any MWDATCore.AnyListenerToken)?
    private var streamSessionErrorToken: (any MWDATCore.AnyListenerToken)?
    private var currentDevice: DeviceInfo?

    // Eager device-reachability observer (dogfood fix 2026-07-12): mirrors
    // Android's attachReachabilityObserver. WITHOUT it the core never learns a
    // wearable's linkState is CONNECTED, so `ensure_capture_session_self_heal`
    // waits forever on is_active_connected() and never fires createDeviceSession
    // — connect hangs at "Connecting…" right after registration.
    private var reachabilityTask: Task<Void, Never>?
    private var linkStateTokens: [any MWDATCore.AnyListenerToken] = []
    private var pendingReachabilityDisconnect: Task<Void, Never>?
    private var didCleanSlateSession = false
    private var cameraPermissionTask: Task<Void, Never>?

    private var videoCaptureTask: Task<Void, Never>?
    private var videoCaptureRequestId: String?

    private var audioSessionActive: Bool = false

    // Outgoing audio (Phase 4 S0.M.1). Lazy-init on first chunk; recreate
    // on sample-rate change; release on teardown. Single engine per bridge
    // instance, matching the Android AudioTrack lifecycle in
    // MetaHardwareBridge.kt:104-113.
    private var outgoingAudioEngine: AVAudioEngine?
    private var outgoingAudioPlayer: AVAudioPlayerNode?
    private var outgoingAudioFormat: AVAudioFormat?
    private var outgoingAudioSampleRate: Double = 0

    private var sttEngine: PlatformSttEngine?
    private var sttHandle: SttEngineHandle?

    private var thermalObserver: NSObjectProtocol?
    private var audioRouteObserver: NSObjectProtocol?
    private var didBackgroundObserver: NSObjectProtocol?
    private var willForegroundObserver: NSObjectProtocol?
    private let callObserver = CXCallObserver()
    private let callObserverDelegate = CallObserverDelegate()
    private var observersWired: Bool = false

    // ── Audio + TTS (constructor-init) ───────────────────────────────────

    let sharedAudioInput: SharedAudioInput
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegateBox()

    init() {
        // Capture-then-bind: the SharedAudioInput callbacks need to flip
        // `audioSessionActive` for the R12 route-change gating below. The
        // class-level reference would normally make `self` capture in init
        // a self-referential closure; routed through a weak holder so the
        // SharedAudioInput doesn't retain the bridge.
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

    func attachCore(_ core: RealMetaCore) {
        lock.lock()
        self.core = core
        lock.unlock()
    }

    /// Tear down scope-owned work. The shell calls this on `shutdown()`.
    /// Idempotent.
    func teardown() {
        stopHardwareObservers()
        reachabilityTask?.cancel()
        reachabilityTask = nil
        lock.lock(); let rtokens = linkStateTokens; linkStateTokens = []; lock.unlock()
        Task { for token in rtokens { await token.cancel() } }
        cancelMWDATTokens()
        videoCaptureTask?.cancel()
        videoCaptureTask = nil
        sttHandle?.close()
        sttEngine = nil
        sttHandle = nil
        releaseOutgoingAudio()
    }

    // ── HardwareBridge: SDK lifecycle ────────────────────────────────────

    func initSdk(requestId: String) {
        // `MWDATCore.Wearables.configure()` is synchronous. `.alreadyConfigured`
        // is benign — the configure call is idempotent in a host-app sense
        // (multiple `RealMetaTransport`s in the same process re-enter).
        do {
            try MWDATCore.Wearables.configure()
            attachReachabilityObserver()
            startEagerCameraPermission()
            corePtr?.onSdkInitResult(requestId: requestId, error: nil)
        } catch WearablesError.alreadyConfigured {
            attachReachabilityObserver()
            startEagerCameraPermission()
            corePtr?.onSdkInitResult(requestId: requestId, error: nil)
        } catch {
            corePtr?.onSdkInitResult(
                requestId: requestId,
                error: BridgeError(
                    code: "sdk_init_failed",
                    message: String(describing: error)
                )
            )
        }
    }

    // ── HardwareBridge: device reachability (link state) ─────────────────

    /// Report each paired wearable's `linkState` to the core via
    /// `onDeviceReachabilityChanged` — the CONNECTED signal the core's
    /// `ensure_capture_session_self_heal` waits on before firing
    /// `create_device_session`. Mirrors Android's `attachReachabilityObserver`.
    /// `devicesStream()` fires only on paired-set changes (NOT connect/drop),
    /// so we also attach per-device `addLinkStateListener` and evaluate the
    /// CURRENT set immediately (the stream may not replay its current value).
    func attachReachabilityObserver() {
        // Called ONLY after MWDATCore.Wearables.configure() succeeds — this is the
        // safe signal that touching Wearables.shared won't trip DAT's not-configured
        // assertion. willEnterForeground gates its reachability re-eval on this.
        lock.lock(); reachabilityReady = true; lock.unlock()
        reachabilityTask?.cancel()
        reachabilityTask = Task { [weak self] in
            guard let self else { return }
            let wearables = MWDATCore.Wearables.shared
            await self.rewireLinkStateListeners(ids: wearables.devices)
            self.evaluateReachability()
            for await ids in wearables.devicesStream() {
                await self.rewireLinkStateListeners(ids: ids)
                self.evaluateReachability()
            }
        }
    }

    private func rewireLinkStateListeners(ids: [MWDATCore.DeviceIdentifier]) async {
        lock.lock(); let old = linkStateTokens; linkStateTokens = []; lock.unlock()
        for token in old { await token.cancel() }
        let wearables = MWDATCore.Wearables.shared
        var fresh: [any MWDATCore.AnyListenerToken] = []
        for id in ids {
            guard let device: MWDATCore.Device = wearables.deviceForIdentifier(id) else { continue }
            let token = device.addLinkStateListener { [weak self] _ in
                self?.evaluateReachability()
            }
            fresh.append(token)
        }
        lock.lock(); linkStateTokens = fresh; lock.unlock()
    }

    private func evaluateReachability() {
        let wearables = MWDATCore.Wearables.shared
        let connected: MWDATCore.Device? = wearables.devices
            .compactMap { (id: MWDATCore.DeviceIdentifier) -> MWDATCore.Device? in
                wearables.deviceForIdentifier(id)
            }
            .first { $0.linkState == MWDATCore.LinkState.connected }
        let info: DeviceInfo? = connected.map { device in
            DeviceInfo(
                id: device.identifier,
                modelName: "Meta Ray-Ban",
                firmwareVersion: "",
                deviceType: .metaRayban,
                vendor: "meta",
                modelId: nil
            )
        }
        if let info = info {
            // Connected → cancel any pending disconnect.
            lock.lock(); pendingReachabilityDisconnect?.cancel(); pendingReachabilityDisconnect = nil; lock.unlock()
            lock.lock(); let appState = appLifecycleStateStr; lock.unlock()
            // iOS gates glasses-SESSION establishment on the FOREGROUND. When the
            // glasses reconnect while the app is backgrounded (off/on / case cycle),
            // reporting CONNECTED here makes the core build the camera session in the
            // background — a born-broken session the user inherits on open (dogfood:
            // "connects to my app before I open it"). Hold it; willEnterForeground
            // re-runs evaluateReachability to establish it in the foreground. The
            // disconnect path is NOT gated, so a background drop still clears a stale
            // session — the reopen then builds a clean one.
            if appState == "background" {
                return
            }
            corePtr?.onDeviceReachabilityChanged(device: info)
            return
        }
        // No connected device → DEBOUNCE. DAT transiently drops the paired set /
        // link during normal operation (esp. around captures); reporting the
        // disconnect immediately triggers a full session reconnect (createSession
        // churn ~every 20s) that destabilizes the stream and makes captures stall.
        // Only report a disconnect if it PERSISTS ~2.5s. (dogfood root cause.)
        lock.lock(); let alreadyPending = pendingReachabilityDisconnect != nil; lock.unlock()
        if alreadyPending { return }
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self else { return }
            self.lock.lock(); self.pendingReachabilityDisconnect = nil; self.lock.unlock()
            let w = MWDATCore.Wearables.shared
            let stillDown = w.devices
                .compactMap { (id: MWDATCore.DeviceIdentifier) -> MWDATCore.Device? in w.deviceForIdentifier(id) }
                .first { $0.linkState == MWDATCore.LinkState.connected } == nil
            if stillDown {
                self.corePtr?.onDeviceReachabilityChanged(device: nil)
            } else {
            }
        }
        lock.lock(); pendingReachabilityDisconnect = task; lock.unlock()
    }

    // ── HardwareBridge: registration ─────────────────────────────────────

    func startRegistration(requestId: String) {
        // iOS registration is a two-part flow: (1) ACTIVELY initiate the Meta
        // AI deeplink via `Wearables.shared.startRegistration()`, then (2) watch
        // `registrationStateStream()` for the outcome. Meta AI returns via the
        // custom URL scheme, forwarded through `RealMetaTransport.handleUrl(_:)`
        // -> `Wearables.handleUrl` (shell-only, per R3). Step 1 mirrors Android's
        // `Wearables.startRegistration(activity)` — without it the Meta AI app
        // never opens and the stream never advances past `.available` (the
        // dogfood bug: registration silently hung until the core's 5-min
        // timeout). iOS's API takes no presenting context; DAT drives the
        // deeplink itself. `.unavailable` still returns cleanly (R2).
        Task { [weak self] in
            guard let self else { return }
            let wearables = MWDATCore.Wearables.shared
            if wearables.registrationState == .registered {
                self.corePtr?.onRegistrationResult(
                    requestId: requestId,
                    outcome: .alreadyRegistered
                )
                return
            }
            // Kick off the Meta AI deeplink. Errors are swallowed; the outcome
            // is read from the stream below (or the core's 5-min backstop) —
            // same posture as Android's runCatching { startRegistration(...) }.
            // Registration persists via a token, but registrationState reads
            // .unavailable right after configure until DAT hydrates it — so we'd
            // needlessly re-run startRegistration() (occasionally re-prompting)
            // every launch. Wait briefly for it to settle before deciding.
            var hydrated = wearables.registrationState
            let hydrateDeadline = Date().addingTimeInterval(2.5)
            while hydrated == .unavailable && Date() < hydrateDeadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                hydrated = wearables.registrationState
            }
            if hydrated == .registered {
                self.corePtr?.onRegistrationResult(
                    requestId: requestId,
                    outcome: .alreadyRegistered
                )
                return
            }
            try? await wearables.startRegistration()
            // Re-check after the deeplink in case registration completed
            // synchronously (mirrors Android's StateFlow.first replaying the
            // current value); the stream may not replay `.registered`.
            if wearables.registrationState == .registered {
                self.corePtr?.onRegistrationResult(
                    requestId: requestId,
                    outcome: .registered
                )
                return
            }
            for await state in wearables.registrationStateStream() {
                switch state {
                case .registered:
                    self.corePtr?.onRegistrationResult(
                        requestId: requestId,
                        outcome: .registered
                    )
                    return
                case .unavailable:
                    self.corePtr?.onRegistrationResult(
                        requestId: requestId,
                        outcome: .unavailable(reason: "registration_unavailable")
                    )
                    return
                default:
                    continue
                }
            }
            // Stream ended without a terminal state — shouldn't happen in
            // practice; the core's REGISTRATION_TIMEOUT_MS (5 min) is the
            // backstop.
            self.corePtr?.onRegistrationResult(
                requestId: requestId,
                outcome: .unavailable(reason: "registration_stream_ended")
            )
        }
    }

    // ── HardwareBridge: device session ───────────────────────────────────

    func createDeviceSession(requestId: String, deviceId: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let wearables = MWDATCore.Wearables.shared
                let selector: any MWDATCore.DeviceSelector
                if let deviceId, !deviceId.isEmpty {
                    selector = MWDATCore.SpecificDeviceSelector(device: deviceId)
                } else {
                    selector = MWDATCore.AutoDeviceSelector(wearables: wearables)
                }
                // DAT CAMERA permission — the Meta-side grant the camera
                // DeviceSession gates on: createSession returns
                // .noEligibleDevice until CAMERA is .granted (parity with
                // Android's ensureWearablesCameraPermission + the load-bearing
                // checkPermissionStatus prime — the dogfood bug where iOS
                // registered fine but never connected). iOS requestPermission
                // is arg-less: DAT drives the Meta AI deeplink and the grant
                // returns via the host app's onOpenURL -> handleUrl.
                self.lock.lock(); let appState = self.appLifecycleStateStr; self.lock.unlock()
                // Load-bearing prime (Android parity): the read-only CAMERA
                // status check right before createSession is required for MWDAT
                // device eligibility. The GRANT is secured EAGERLY at initSdk so
                // this never prompts and the core's session-retry loop can't
                // spawn a duplicate Meta AI consent prompt.
                _ = try? await wearables.checkPermissionStatus(MWDATCore.Permission.camera)
                // CLEAN-SLATE for a LEAKED glasses-side session: a force-quit
                // leaves a stale session on the glasses, so the FIRST createSession
                // on a fresh launch is "born broken". Mirror the connection-page
                // reload (a 2nd connect clears it): create the possibly-stale
                // session, release it, then create fresh. Once per process.
                var cleanSlateDone = false
                self.lock.lock(); cleanSlateDone = self.didCleanSlateSession; if !cleanSlateDone { self.didCleanSlateSession = true }; self.lock.unlock()
                if !cleanSlateDone {
                    if let stale = try? wearables.createSession(deviceSelector: selector) {
                        stale.stop()
                        try? await Task.sleep(nanoseconds: 700_000_000)
                    } else {
                    }
                }
                let session = try wearables.createSession(deviceSelector: selector)
                let info = DeviceInfo(
                    id: session.deviceId,
                    modelName: "Meta Ray-Ban",
                    firmwareVersion: "",
                    deviceType: .metaRayban,
                    vendor: "meta",
                    // Wire-id mapping (Kotlin wireIdOf) lands with the DAT 0.8 port.
                    modelId: nil
                )
                self.lock.lock()
                self.deviceSession = session
                self.currentDevice = info
                self.lock.unlock()
                self.corePtr?.onDeviceSessionCreated(
                    requestId: requestId,
                    info: info,
                    error: nil
                )
            } catch MWDATCore.DeviceSessionError.noEligibleDevice {
                self.corePtr?.onDeviceSessionCreated(
                    requestId: requestId,
                    info: nil,
                    error: .noEligibleDevice
                )
            } catch {
                self.corePtr?.onDeviceSessionCreated(
                    requestId: requestId,
                    info: nil,
                    error: .platformError(
                        code: "create_session_failed",
                        message: String(describing: error)
                    )
                )
            }
        }
    }

    /// Secure the MWDAT CAMERA grant ONCE, eagerly (Android parity: initSdk
    /// launches ensureCameraPermission on its own coroutine). Doing it here —
    /// NOT inline in createDeviceSession — means the core's session-retry loop
    /// never spawns a duplicate Meta AI consent prompt (dogfood: camera
    /// prompted twice + sessionAlreadyExists).
    private func startEagerCameraPermission() {
        lock.lock()
        if cameraPermissionTask != nil { lock.unlock(); return }
        cameraPermissionTask = Task { [weak self] in
            await Self.ensureWearablesCameraPermission()
            guard let self else { return }
            self.lock.lock(); self.cameraPermissionTask = nil; self.lock.unlock()
        }
        lock.unlock()
    }

    /// MWDAT Wearables CAMERA permission — the Meta-side grant the camera
    /// DeviceSession gates on (`createSession` returns `.noEligibleDevice`
    /// until it's `.granted`). Mirrors Android's
    /// `ensureWearablesCameraPermission`. `checkPermissionStatus` throws
    /// (`.noDevice*`) until the glasses are connected, so poll for a
    /// definitive status before deciding — the grant persists across
    /// launches, so we must not re-prompt on connect churn. iOS
    /// `requestPermission` is arg-less: DAT drives the Meta AI deeplink and
    /// the grant returns via the host app's `onOpenURL` -> `handleUrl`.
    /// No-ops for apps declaring no camera usage string (audio-only),
    /// matching Android's `cameraDeclared()` gate.
    private static func ensureWearablesCameraPermission() async {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else { return }
        let wearables = MWDATCore.Wearables.shared
        // Bounded 8s (NOT 300s) — must never block the connect walk; if the
        // status never resolves we proceed and let createSession surface the
        // real error (instrumented).
        let statusDeadline = Date().addingTimeInterval(8)
        var status: MWDATCore.PermissionStatus? = nil
        while Date() < statusDeadline {
            do {
                status = try await wearables.checkPermissionStatus(MWDATCore.Permission.camera)
                break
            } catch {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard let status else { return }
        if status == .granted { return }
        do {
            let r = try await wearables.requestPermission(MWDATCore.Permission.camera)
        } catch {
        }
        let grantDeadline = Date().addingTimeInterval(30)
        while Date() < grantDeadline {
            if (try? await wearables.checkPermissionStatus(MWDATCore.Permission.camera)) == .granted { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func startDeviceSession(requestId: String) {
        // Attach the state observer BEFORE calling start() — otherwise we
        // miss the `.starting` / `.started` transitions that drive the
        // core's `on_device_state_changed` → `GlassesState::Active`.
        Task { [weak self] in
            guard let self else { return }
            let session = self.snapshotDeviceSession()
            guard let session = session else {
                self.corePtr?.onDeviceSessionStarted(
                    requestId: requestId,
                    error: .platformError(
                        code: "no_session",
                        message: "createDeviceSession not called"
                    )
                )
                return
            }
            self.attachDeviceSessionListeners(session: session)
            do {
                try session.start()
                self.corePtr?.onDeviceSessionStarted(
                    requestId: requestId,
                    error: nil
                )
            } catch MWDATCore.DeviceSessionError.noEligibleDevice {
                self.corePtr?.onDeviceSessionStarted(
                    requestId: requestId,
                    error: .noEligibleDevice
                )
            } catch {
                self.corePtr?.onDeviceSessionStarted(
                    requestId: requestId,
                    error: .platformError(
                        code: "start_session_failed",
                        message: String(describing: error)
                    )
                )
            }
        }
    }

    func stopDeviceSession() {
        let session = takeDeviceSession()
        cancelDeviceSessionTokens()
        session?.stop()
    }

    // ── HardwareBridge: stream session ───────────────────────────────────

    func openStream(requestId: String, config: OpenStreamConfig) {
        Task { [weak self] in
            guard let self else { return }
            // Route through the shared stream-readiness protocol (Android
            // ensureStreamArmed parity): reuse a live .raw stream or arm one,
            // and report opened ONLY once it is genuinely STREAMING. .raw =
            // per-frame-decodable frames (frame-grab + on-device preview).
            switch await self.ensureStreamArmed(
                codec: .raw,
                resolution: Self.mapResolution(config.resolution),
                frameRate: UInt(max(1, config.frameRate))
            ) {
            case .streaming:
                self.corePtr?.onStreamOpened(requestId: requestId, error: nil)
            case .paused:
                self.corePtr?.onStreamOpened(
                    requestId: requestId,
                    error: BridgeError(code: "not_streaming", message: "Stream paused — tap the right temple to resume")
                )
            case .failed:
                self.corePtr?.onStreamOpened(
                    requestId: requestId,
                    error: BridgeError(code: "open_stream_failed", message: "stream did not reach streaming")
                )
            }
        }
    }

    func closeStream() {
        let stream = takeStreamSession()
        cancelStreamSessionTokens()
        stream?.stop()
    }

    // ── HardwareBridge: discrete captures ────────────────────────────────

    /// Decode a DAT video frame to a UIImage. `makeUIImage()` returns nil for
    /// this stream's frames on real hardware, so fall back to the
    /// CMSampleBuffer's decoded pixel buffer via CoreImage. Logs the media
    /// subtype if neither works (compressed frame -> would need VTDecompression).
    /// Open a camera stream for a DISCRETE photo WITHOUT start()-ing frame
    /// streaming. A discrete capturePhoto on a streaming stream races the
    /// frame flow and trips Meta's frame-stall watchdog (build 13: worked once,
    /// then stalled+killed the stream). No start() = no frames = nothing to
    /// stall. Reuses an existing stream if one is already open.
    /// Wait (bounded) for the stream to reach STREAMING. Firing capturePhoto on
    /// a non-streaming stream (waitingForDevice/starting) returns fired=false
    /// and destabilizes it (dogfood: it then goes .stopped). Poll the state.
    private func waitForStreaming(_ stream: MWDATCamera.Stream, timeoutMs: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if stream.state == MWDATCamera.StreamState.streaming { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return stream.state == MWDATCamera.StreamState.streaming
    }

    /// One discrete capturePhoto attempt on `stream` with a 10s backstop.
    /// Returns nil if the stream rejected the capture (fired=false) or no
    /// PhotoData arrived in time.
    private func fireDiscreteCapture(_ stream: MWDATCamera.Stream, format: PhotoFormat) async -> MWDATCamera.PhotoData? {
        let oneShot = OneShotBox<MWDATCamera.PhotoData>()
        return await withCheckedContinuation { (cont: CheckedContinuation<MWDATCamera.PhotoData?, Never>) in
            let token = stream.photoDataPublisher.listen { data in
                oneShot.resume(with: data, continuation: cont)
            }
            let fired = stream.capturePhoto(format: Self.photoFormat(format))
            if !fired {
                oneShot.resume(with: nil, continuation: cont)
                Task { await token.cancel() }
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                oneShot.resume(with: nil, continuation: cont)
                await token.cancel()
            }
        }
    }

    /// Drop the current photo stream (stop + clear) so the next
    /// ensurePhotoStreamNoStart opens a fresh one — used when a stream is torn
    /// down (user closed it via the temple gesture) and capture starts failing.
    private func discardPhotoStream() {
        // Proper teardown (mirror closeStream): cancel the listener tokens so
        // the Stream can deallocate, then stop it. Otherwise the session's
        // stream slot stays occupied and the next addStream returns nil
        // (dogfood: stuck stream = whole-session capture failure, no recovery).
        let stream = takeStreamSession()
        cancelStreamSessionTokens()
        stream?.stop()
    }

    private enum StreamArm {
        case streaming(MWDATCamera.Stream)
        case paused
        case failed
    }

    private static func isLiveOrComingUp(_ s: MWDATCamera.StreamState) -> Bool {
        return s == MWDATCamera.StreamState.streaming
            || s == MWDATCamera.StreamState.starting
            || s == MWDATCamera.StreamState.waitingForDevice
    }

    private static func isTerminalStreamState(_ s: MWDATCamera.StreamState) -> Bool {
        return s == MWDATCamera.StreamState.stopped || s == MWDATCamera.StreamState.stopping
    }

    /// Close a stream and WAIT for it to reach STOPPED. stop() is async — the
    /// camera capability / WARP media channel is PROCESS-WIDE and stays held until
    /// the stream actually stops, so arming a new stream (esp. a different codec)
    /// before then throws `capabilityAlreadyActive` and kills the camera (dogfood:
    /// frame-grab→full-res / →video swap). Android waits the same way
    /// (STREAM_CLOSE_WAIT_MS). Recreating the device session does NOT free it — the
    /// capability is tied to the stream closing, not the session.
    private func closeStreamAndWait(_ stream: MWDATCamera.Stream) async {
        stream.stop()
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if stream.state == MWDATCamera.StreamState.stopped { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Android `ensureDeviceSessionStarted` parity: after a reap (tap-and-hold close
    /// → STOPPED session), DISCARD the stale session/stream handles WITHOUT stopping
    /// them (the reap already ended them; stopping can re-hold the capability on iOS),
    /// then build a FRESH session in-process — createSession → start() → wait STARTED.
    /// Returns true when the fresh session is STARTED and ready for addStream. Android
    /// does this with "no power-cycle needed".
    private func rebuildDeviceSessionLikeAndroid() async -> Bool {
        // Tear down the reaped stream + session FIRST — iOS createSession throws
        // sessionAlreadyExists if the old session handle still lingers SDK-side
        // (dogfood build 40: createSession returned nil without this; Android's reap
        // fully ends it so Android can skip the stop, iOS can't).
        let oldStream = takeStreamSession(); cancelStreamSessionTokens(); oldStream?.stop()
        let oldSession = takeDeviceSession(); cancelDeviceSessionTokens(); oldSession?.stop()
        lock.lock(); streamCodec = nil; lock.unlock()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let wearables = MWDATCore.Wearables.shared
        // Right after a close the device is transiently NOT eligible (dogfood build
        // 41: createSession threw noEligibleDevice while still paired=1). The
        // load-bearing checkPermissionStatus prime + a bounded createSession retry
        // lets it settle back to eligible without waiting for a full BT cycle.
        for attempt in 0..<8 {
            let status = try? await wearables.checkPermissionStatus(MWDATCore.Permission.camera)
            do {
                let session = try wearables.createSession(deviceSelector: MWDATCore.AutoDeviceSelector(wearables: wearables))
                lock.lock(); deviceSession = session; lock.unlock()
                attachDeviceSessionListeners(session: session)
                // START + wait STARTED (Android calls created.start(); addStream on a
                // non-STARTED session fails).
                do { try session.start() } catch {
                }
                let deadline = Date().addingTimeInterval(8.0)
                while Date() < deadline {
                    if session.state == MWDATCore.DeviceSessionState.started { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                return session.state == MWDATCore.DeviceSessionState.started
            } catch {
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
        return false
    }

    /// Bridge-internal, core-transparent device-session re-create (Android
    /// `resetDeviceSession` parity). A stale idle-since-connect session never
    /// brings a fresh stream to STREAMING — the "reopen the app a few times"
    /// cold-start stall / born-broken reopen. Tear stream+session down and make
    /// a fresh one on the same device; the core keeps believing it holds a
    /// session (no onDeviceSessionCreated churn) — a manual app-reopen, automated.
    private func recreateDeviceSessionInternal() async {
        let oldStream = takeStreamSession()
        cancelStreamSessionTokens()
        if let oldStream = oldStream { await closeStreamAndWait(oldStream) }
        let oldSession = takeDeviceSession()
        cancelDeviceSessionTokens()
        oldSession?.stop()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let wearables = MWDATCore.Wearables.shared
        lock.lock(); let devId = currentDevice?.id; lock.unlock()
        let selector: any MWDATCore.DeviceSelector
        if let devId = devId, !devId.isEmpty {
            selector = MWDATCore.SpecificDeviceSelector(device: devId)
        } else {
            selector = MWDATCore.AutoDeviceSelector(wearables: wearables)
        }
        _ = try? await wearables.checkPermissionStatus(MWDATCore.Permission.camera)
        if let session = try? wearables.createSession(deviceSelector: selector) {
            lock.lock(); deviceSession = session; lock.unlock()
            attachDeviceSessionListeners(session: session)
        } else {
        }
    }

    /// The single stream-readiness protocol for every path that needs the live
    /// feed (photo, video, preview) — Android `ensureStreamArmed` parity. Reuse
    /// the warm stream if it is the SAME codec and live/coming-up (iOS shares one
    /// slot: .raw = frame-grab-decodable, .hvc1 = video/discrete); else swap+arm.
    /// Then WAIT for STREAMING. If it won't come up: PAUSED is a system hold (the
    /// user must tap the right temple to resume) — surface it, don't churn; any
    /// other stall is a stale device session, so re-create it and retry (up to 3x).
    private func ensureStreamArmed(
        codec: MWDATCamera.VideoCodec,
        resolution: MWDATCamera.StreamingResolution,
        frameRate: UInt
    ) async -> StreamArm {
        for attempt in 0..<3 {
            lock.lock()
            let existing = streamSession
            let existingCodec = streamCodec
            lock.unlock()
            // A live stream that is PAUSED (user tapped the temple — a SYSTEM hold,
            // no app-callable resume) must be SURFACED, never torn down: it fails
            // isLiveOrComingUp below, so without this it would fall into the swap
            // branch and close the stream (dogfood: paused capture errored + tore
            // the stream down). Closing it would also collapse the WARP channel, and
            // it resumes on the next temple tap. Android parity: isTerminalStreamState
            // excludes PAUSED, so Android holds it too.
            if let existing = existing, existing.state == MWDATCamera.StreamState.paused {
                return .paused
            }
            var stream: MWDATCamera.Stream?
            var armThrew = false
            if let existing = existing, existingCodec == codec, Self.isLiveOrComingUp(existing.state) {
                stream = existing
            } else if let existing = existing, existingCodec == codec, Self.isTerminalStreamState(existing.state) {
                // Reopen after a tap-and-hold close: re-start THE existing stream.
                // iOS holds the camera capability process-wide with NO foreground
                // release — a fresh createSession throws noEligibleDevice /
                // capabilityAlreadyActive until the glasses BT-cycle (dogfood builds
                // 37-42: the rebuild never reopens). Re-starting the existing stream
                // is the ONLY thing that reopens immediately — capture works. The
                // glasses' temple-gesture UI re-engages only after a background/
                // BT-cycle (a known iOS DAT gap: Android has removeStream, iOS does
                // not — so iOS can't build a fresh gesture-bound stream in-process).
                existing.start()
                stream = existing
            } else {
                if existing != nil {
                    let old = takeStreamSession()
                    cancelStreamSessionTokens()
                    if let old = old { await closeStreamAndWait(old) }
                }
                guard let session = snapshotDeviceSession() else {
                    return .failed
                }
                let cfg = MWDATCamera.StreamConfiguration(
                    videoCodec: codec,
                    resolution: resolution,
                    frameRate: max(1, frameRate)
                )
                do {
                    if let opened = try session.addStream(config: cfg) {
                        opened.start()
                        lock.lock(); streamSession = opened; streamCodec = codec; lock.unlock()
                        attachStreamSessionListeners(stream: opened)
                        stream = opened
                    }
                } catch {
                    armThrew = true
                }
            }
            if let stream = stream, await waitForStreaming(stream, timeoutMs: 5000) {
                return .streaming(stream)
            }
            if let stream = stream, stream.state == MWDATCamera.StreamState.paused {
                return .paused
            }
            if armThrew || stream == nil {
                // addStream failed — usually `capabilityAlreadyActive`: the prior
                // stream's PROCESS-WIDE camera capability hasn't released yet (stop()
                // is async). Recreating the session does NOT free it (it's tied to the
                // stream closing, not the session). Settle and retry the arm.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } else {
                // Armed but never reached STREAMING = stale idle device session → recreate.
                await recreateDeviceSessionInternal()
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        return .failed
    }

    private static func decodeFrameToImage(_ frame: MWDATCamera.VideoFrame?) -> UIImage? {
        guard let frame else { return nil }
        if let img = frame.makeUIImage() { return img }
        let sb = frame.sampleBuffer
        if let pb = CMSampleBufferGetImageBuffer(sb) {
            let ci = CIImage(cvPixelBuffer: pb)
            let ctx = CIContext(options: nil)
            if let cg = ctx.createCGImage(ci, from: ci.extent) {
                return UIImage(cgImage: cg)
            }
            return nil
        }
        let sub = CMSampleBufferGetFormatDescription(sb).map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        return nil
    }

    func capturePhoto(requestId: String, format: PhotoFormat, frameGrab: Bool) {
        Task { [weak self] in
            guard let self else { return }
            // Stream-readiness protocol (Android ensureStreamArmed parity): get a
            // genuinely STREAMING stream. iOS runs the WHOLE photo session on ONE
            // codec — .raw — for BOTH mechanisms: frame-grab decodes .raw frames,
            // and the discrete still is codec-independent (a separate capture).
            // Swapping codecs is impossible on non-DAM DAT 0.8: closing one stream
            // to open another collapses the process-wide WARP media channel — the
            // new stream comes up then dies (dogfood build 28). One warm .raw
            // stream, never swapped; PAUSED = system hold (tap temple) → surfaced.
            let stream: MWDATCamera.Stream
            switch await self.ensureStreamArmed(codec: .raw, resolution: .medium, frameRate: 24) {
            case .streaming(let s):
                stream = s
            case .paused:
                self.corePtr?.onPhotoCaptured(
                    requestId: requestId,
                    photo: nil,
                    // Android parity: code `not_streaming`, surfaced via the same
                    // capture-result channel so an AI agent gets identical context.
                    error: BridgeError(code: "not_streaming", message: "Stream paused — tap the right temple to resume")
                )
                return
            case .failed:
                self.corePtr?.onPhotoCaptured(
                    requestId: requestId,
                    photo: nil,
                    error: BridgeError(code: "no_stream", message: "stream did not reach streaming")
                )
                return
            }
            // Honor the core's frame_grab decision (frame_grab = !full_resolution).
            // frame-grab → grab a frame off the live .raw stream (per-frame
            // decodable → makeUIImage; can't trip Meta's frame-stall watchdog;
            // Android parity). discrete → Meta's stream.capturePhoto() full-sensor
            // still on an .hvc1 stream (higher-res, but exposed to DAT's documented
            // quick-succession-on-long-stream stall). ensureStream() opened the
            // matching codec above.
            let frameGrabIOS = frameGrab
            if frameGrabIOS {
                // Frame-grab (the default path): one frame off the live stream —
                // a frame-grab can't trip Meta's frame-stall watchdog the way a
                // discrete capturePhoto racing the stream does. Meta decodes for
                // us (VideoFrame.makeUIImage), so the RDQ #47 JPEG contract costs
                // none of the Kotlin bridge's I420 hand-rolling. Same one-shot +
                // 10 s backstop shape as the discrete path below.
                let oneShot = OneShotBox<MWDATCamera.VideoFrame>()
                let frame: MWDATCamera.VideoFrame? = await withCheckedContinuation {
                    (cont: CheckedContinuation<MWDATCamera.VideoFrame?, Never>) in
                    let token = stream.videoFramePublisher.listen { f in
                        oneShot.resume(with: f, continuation: cont)
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        oneShot.resume(with: nil, continuation: cont)
                        await token.cancel()
                    }
                }
                let decoded = Self.decodeFrameToImage(frame)
                guard let image = decoded,
                      let jpeg = image.jpegData(compressionQuality: 0.9) else {
                    self.corePtr?.onPhotoCaptured(
                        requestId: requestId,
                        photo: nil,
                        error: BridgeError(
                            code: "frame_grab_timeout",
                            message: "no decodable video frame within 10s"
                        )
                    )
                    return
                }
                let url = Self.writeTempFile(data: jpeg, ext: "jpg")
                self.corePtr?.onPhotoCaptured(
                    requestId: requestId,
                    // A frame-grab is always JPEG (the normalization contract);
                    // dimensions are real — decoded, not the R7 fallback.
                    photo: CapturedPhoto(
                        uri: url.absoluteString,
                        width: Int32(image.size.width * image.scale),
                        height: Int32(image.size.height * image.scale),
                        format: .jpeg
                    ),
                    error: nil
                )
                return
            }
            // One-shot consumer of photoDataPublisher with a 10 s timeout
            // backstop. The publisher is the iOS analogue of Android's
            // `streamSession.capturePhoto()` suspend — we listen, fire,
            // race the next emission against a sleep.
            // Capture with retries: fired=false means the stream isn't ready
            // (first shot right after open) or was torn down (user closed the
            // stream via the temple gesture). Retry the same stream once after a
            // settle, then refresh to a fresh stream once. (dogfood: 1st-shot +
            // post-close both failed with fired=false.)
            // Android parity: on failure, REPORT and leave the stream alone. My
            // build 16/17 discard+re-add REGRESSED — the discard's stop() reaped
            // the session (Asger: retry/self-heal machinery tends to regress; fix
            // the root cause). One same-stream retry after a settle covers the
            // not-ready first shot; a persistent failure just reports.
            // Only capture when the stream is STREAMING (Android parity). Firing
            // on a not-ready stream (waitingForDevice) returns fired=false and
            // can leave it .stopped — the whole failure mode we saw. Wait for it.
            let streaming = await self.waitForStreaming(stream, timeoutMs: 5000)
            var photoData: MWDATCamera.PhotoData? = nil
            if streaming {
                // Settle: a capture fired right after the stream JUST reached
                // streaming gets stuck (fires, never delivers/errors) and jams ALL
                // later captures (DAT rejects them: fired=false). Let it stabilize
                // first. (dogfood: first-shot-after-fresh-stream stall.)
                try? await Task.sleep(nanoseconds: 700_000_000)
                photoData = await self.fireDiscreteCapture(stream, format: format)
            }
            guard let photoData = photoData else {
                self.corePtr?.onPhotoCaptured(
                    requestId: requestId,
                    photo: nil,
                    error: BridgeError(
                        code: "capture_photo_timeout",
                        message: "no photoDataPublisher emission within 10s"
                    )
                )
                return
            }
            let ext = photoData.format == .jpeg ? "jpg" : "heic"
            let url = Self.writeTempFile(data: photoData.data, ext: ext)
            // R7: dimensions stay best-effort (1280x720) until a HEIC
            // decode probe lands in Phase 2c. Android mirrors this for
            // its HEIC variant; iOS uses the same fallback across formats
            // because `MWDATCamera.PhotoData` does not expose dimensions
            // on either variant in the 0.6 SDK.
            self.corePtr?.onPhotoCaptured(
                requestId: requestId,
                photo: CapturedPhoto(
                    uri: url.absoluteString,
                    width: 1280,
                    height: 720,
                    format: format
                ),
                error: nil
            )
        }
    }

    func captureVideo(requestId: String, config: VideoCaptureConfig) {
        // Track the in-flight Task so `abortVideoCapture` can cancel it.
        // `VideoCaptureSession.run()` honours Task cancellation by breaking
        // the frame loop and finalizing the partial; the resulting
        // ExtentosResult arrives via `on_video_captured`.
        let task = Task { [weak self] in
            guard let self else { return }
            let stream: MWDATCamera.Stream
            switch await self.ensureStreamArmed(codec: .raw, resolution: .medium, frameRate: 30) {
            case .streaming(let s):
                stream = s
            case .paused:
                // Surface the SAME paused error the photo path does — a stream held
                // by a temple tap reports identically for EVERY capability that needs
                // the live feed, so the app/agent gets one consistent signal.
                self.corePtr?.onVideoCaptured(
                    requestId: requestId,
                    video: nil,
                    error: BridgeError(code: "not_streaming", message: "Stream paused — tap the right temple to resume")
                )
                self.clearVideoCapture(requestId: requestId)
                return
            case .failed:
                self.corePtr?.onVideoCaptured(
                    requestId: requestId,
                    video: nil,
                    error: BridgeError(
                        code: "no_stream",
                        message: "could not open stream session"
                    )
                )
                self.clearVideoCapture(requestId: requestId)
                return
            }
            let frames = AsyncStream<CMSampleBuffer> { continuation in
                let bridge = AsyncStream<MWDATCamera.VideoFrame>.fromAnnouncer(stream.videoFramePublisher)
                let task = Task {
                    for await frame in bridge {
                        continuation.yield(frame.sampleBuffer)
                    }
                    continuation.finish()
                }
                // Auto-finalize the recording the moment the stream STOPS (e.g. a
                // tap-and-hold close mid-record): no more frames will ever arrive, so
                // end the clip NOW instead of hanging until a manual Stop — the saved
                // length then matches the actual footage (dogfood polish). A PAUSE
                // (temple tap) is NOT terminal — frames just freeze — so we do not end
                // on .paused. iOS-shell parity with Android, whose VideoCaptureSession
                // watches the streamSession state directly.
                let stopToken = stream.statePublisher.listen { state in
                    switch state {
                    case .stopping, .stopped:
                        continuation.finish()
                    default:
                        break
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                    Task { await stopToken.cancel() }
                }
            }
            // R8 honoured — iOS plumbs `includeAudio` through
            // `VideoCaptureSession`, which wires the audioInput when set
            // (Android still ignores the flag pending Sprint 5 work).
            let session = VideoCaptureSession(
                videoFrames: frames,
                audioInput: config.includeAudio ? self.sharedAudioInput : nil,
                config: VideoConfig(
                    resolution: .medium,
                    maxDurationSeconds: config.maxDurationSeconds.map(Int.init),
                    format: config.format,
                    includeAudio: config.includeAudio
                )
            )
            let result = await session.run()
            switch result {
            case .success(let clip):
                self.corePtr?.onVideoCaptured(
                    requestId: requestId,
                    video: CapturedVideo(
                        uri: clip.uri,
                        durationMs: clip.durationMs,
                        width: clip.width,
                        height: clip.height,
                        format: clip.format
                    ),
                    error: nil
                )
            case .failure(let err):
                self.corePtr?.onVideoCaptured(
                    requestId: requestId,
                    video: nil,
                    error: BridgeError(
                        code: "capture_video_failed",
                        message: captureErrorMessage(error: err)
                    )
                )
            }
            self.clearVideoCapture(requestId: requestId)
        }
        lock.lock()
        videoCaptureTask = task
        videoCaptureRequestId = requestId
        lock.unlock()
    }

    func abortVideoCapture(requestId: String) {
        // Cancel the in-flight VideoCaptureSession task; its for-await
        // loop checks `Task.isCancelled` per frame and finalises the
        // partial. The captureVideo Task's completion path then fires
        // `on_video_captured`. If nothing's in flight, synthesise an
        // error so the core's pending op doesn't hang.
        lock.lock()
        let task = videoCaptureTask
        let inFlightId = videoCaptureRequestId
        videoCaptureTask = nil
        videoCaptureRequestId = nil
        lock.unlock()
        if let task = task {
            task.cancel()
        } else {
            corePtr?.onVideoCaptured(
                requestId: inFlightId ?? requestId,
                video: nil,
                error: BridgeError(
                    code: "no_video_in_flight",
                    message: "abortVideoCapture called with no in-flight capture"
                )
            )
        }
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

    // ── HardwareBridge: STT ──────────────────────────────────────────────

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

    // ── HardwareBridge: output ───────────────────────────────────────────

    func speak(requestId: String, text: String, config: SpeakConfigWire) {
        let utterance = AVSpeechUtterance(string: text)
        if let voice = config.voice {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voice)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
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

    func earcon(sound: EarconSound, volume: Float) {
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
    func playOutgoingAudioChunk(sampleRate: Int32, pcmBytes: Data) {
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
    func flushOutgoingAudio() {
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

    // ── HardwareBridge: hardware observers ───────────────────────────────

    func startHardwareObservers() {
        lock.lock()
        let already = observersWired
        if !already { observersWired = true }
        lock.unlock()
        if already { return }
        wireThermal()
        wireAudioRoute()
        wireLifecycle()
        wireCallObserver()
        // R14: no iOS phone-notification observer today — left as a
        // Phase-4 follow-up. There's no equivalent of Android's
        // `NotificationListenerService` exposed to third-party apps
        // without entitlements we don't request.
    }

    func stopHardwareObservers() {
        lock.lock()
        let active = observersWired
        observersWired = false
        let toRemove = [
            thermalObserver, audioRouteObserver,
            didBackgroundObserver, willForegroundObserver,
        ]
        thermalObserver = nil
        audioRouteObserver = nil
        didBackgroundObserver = nil
        willForegroundObserver = nil
        lock.unlock()
        if !active { return }
        let center = NotificationCenter.default
        for observer in toRemove {
            if let observer = observer {
                center.removeObserver(observer)
            }
        }
        callObserver.setDelegate(nil, queue: nil)
    }

    func hasMicPermission() -> Bool {
        let granted = AVAudioSession.sharedInstance().recordPermission == .granted
        return granted
    }

    // ── Shell-internal: streaming primitives that bypass the core ────────

    /// Customer-facing `videoFrames` stream. Opens a stream session if
    /// needed (lazy) and subscribes to its `videoFramePublisher`. Does NOT
    /// go through the core — the core has no work to do for video-frame
    /// multiplexing (R10's video twin).
    func videoFramesStream(config: VideoFrameConfig) -> AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                guard let stream = await self.ensureStreamSessionForVideo(frameRate: UInt(max(1, config.frameRate))) else {
                    continuation.finish()
                    return
                }
                let frames = AsyncStream<MWDATCamera.VideoFrame>.fromAnnouncer(stream.videoFramePublisher)
                // Monotonic guard (EgoFlow feedback 2026-07-16, Kotlin parity):
                // DAT's presentation clock rebases when the keep-warm stream
                // re-arms (reconnect / re-open), so raw timestamps can
                // duplicate or regress. Guarantee strictly-increasing per
                // stream: a non-advancing source timestamp clamps to
                // previous+1 µs; an advancing one passes through untouched.
                var lastTsUs = Int64.min
                for await frame in frames {
                    // RDQ #47 contract: `VideoFrame.data` is JPEG on every
                    // substrate. Meta decodes for us (makeUIImage) — none of
                    // the Kotlin bridge's I420 hand-rolling. Undecodable
                    // frames are skipped, never yielded empty.
                    guard let image = frame.makeUIImage(),
                          let jpeg = image.jpegData(compressionQuality: 0.85) else { continue }
                    let sourceTsUs = Int64(
                        CMTimeGetSeconds(frame.sampleBuffer.presentationTimeStamp) * 1_000_000
                    )
                    let tsUs = sourceTsUs > lastTsUs ? sourceTsUs : lastTsUs + 1
                    lastTsUs = tsUs
                    continuation.yield(VideoFrame(
                        buffer: jpeg,
                        width: Int(image.size.width * image.scale),
                        height: Int(image.size.height * image.scale),
                        presentationTimeUs: tsUs,
                        isCompressed: true
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Customer-facing `audioChunks` stream. Subscribes to the shared
    /// `SharedAudioInput` — coexists with `record_audio` /
    /// `transcriptions` / `capture_video` audio (R10: one tap per node).
    /// Bypasses the core by design.
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

    // ── Listeners ────────────────────────────────────────────────────────

    private func attachDeviceSessionListeners(session: MWDATCore.DeviceSession) {
        cancelDeviceSessionTokens()
        let stateToken = session.statePublisher.listen { [weak self] state in
            self?.handleDeviceSessionState(state)
        }
        let errorToken = session.errorPublisher.listen { [weak self] error in
            self?.corePtr?.onTransportError(
                error: .platformError(wrapping: PlatformErrorBox(error: error))
            )
        }
        lock.lock()
        deviceSessionStateToken = stateToken
        deviceSessionErrorToken = errorToken
        lock.unlock()
    }

    private func attachStreamSessionListeners(stream: MWDATCamera.Stream) {
        cancelStreamSessionTokens()
        let stateToken = stream.statePublisher.listen { [weak self] state in
            guard let self else { return }
            // 0.8's iOS vocabulary has NO `closed` case (teardown surfaces via
            // errorPublisher) and adds `waitingForDevice` (pre-start hold).
            // Paused semantics are core-owned (held ≠ live ≠ dead — the core
            // drops stream_live and does NOT treat it as a disconnect).
            let mapped: StreamState
            switch state {
            case .waitingForDevice: mapped = .starting
            case .starting: mapped = .starting
            case .streaming: mapped = .streaming
            case .paused: mapped = .paused
            case .stopping: mapped = .stopping
            case .stopped: mapped = .stopped
            }
            self.corePtr?.onStreamStateChanged(state: mapped)
        }
        let errorToken = stream.errorPublisher.listen { [weak self] error in
            guard let self else { return }
            switch error {
            case .hingesClosed:
                self.corePtr?.onHingesClosed()
            case .thermalCritical:
                self.corePtr?.onThermalAlert(severity: .critical)
            case .permissionDenied:
                self.corePtr?.onTransportError(
                    error: .platformError(wrapping: PlatformErrorBox(error: error))
                )
            case .timeout, .internalError, .videoStreamingError:
                // Transient capture/stream errors: log only. Do NOT escalate to a
                // transport failure — that tears the whole session down/reconnects.
                // A failed photo shouldn't kill the session (root-cause, not a retry
                // loop). The stream may already be .stopped DAT-side; the app can
                // resume, and we avoid compounding it with a core-side disconnect.
                break
            default:
                self.corePtr?.onTransportError(
                    error: .platformError(wrapping: PlatformErrorBox(error: error))
                )
            }
        }
        lock.lock()
        streamSessionStateToken = stateToken
        streamSessionErrorToken = errorToken
        lock.unlock()
    }

    private func handleDeviceSessionState(_ state: MWDATCore.DeviceSessionState) {
        // R1 — iOS's 6-state `DeviceSessionState` maps directly onto the
        // normalized `DeviceState` enum the core consumes; no synthesis
        // needed (that's the easy half — Android synthesises starting /
        // paused / stopping that its SDK doesn't expose).
        let mapped: DeviceState
        switch state {
        case .idle: mapped = .idle
        case .starting: mapped = .starting
        case .started: mapped = .started
        case .paused: mapped = .paused
        case .stopping: mapped = .stopping
        case .stopped: mapped = .stopped
        }
        corePtr?.onDeviceStateChanged(state: mapped)
    }

    // ── Hardware observer wiring ─────────────────────────────────────────

    private func wireThermal() {
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            if let severity = Self.mapThermalState(ProcessInfo.processInfo.thermalState) {
                self.corePtr?.onThermalAlert(severity: severity)
            }
        }
        lock.lock(); thermalObserver = observer; lock.unlock()
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

    private func wireLifecycle() {
        let center = NotificationCenter.default
        let didBackground = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.appLifecycleStateStr = "background"; self.lock.unlock()
            self.corePtr?.onAppLifecycleChanged(toState: .background)
        }
        let willForeground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.appLifecycleStateStr = "foreground"; self.lock.unlock()
            self.corePtr?.onAppLifecycleChanged(toState: .foreground)
            // Establish (or refresh) the glasses session now that we're foreground —
            // a reconnect that arrived while backgrounded was held above. Guard on
            // SDK-ready: willEnterForeground can fire mid-launch BEFORE
            // Wearables.configure() finishes, and touching Wearables.shared then trips
            // a DAT assertion (crash-loop, build 31). attachReachabilityObserver
            // (post-configure) flips the flag; its own evaluateReachability covers the
            // cold-launch path.
            self.lock.lock(); let ready = self.reachabilityReady; self.lock.unlock()
            if ready { self.evaluateReachability() }
        }
        lock.lock()
        didBackgroundObserver = didBackground
        willForegroundObserver = willForeground
        lock.unlock()
    }

    private func wireCallObserver() {
        callObserverDelegate.onCall = { [weak self] call in
            let state: CallState
            if call.hasEnded { state = .idle }
            else if call.hasConnected { state = .offhook }
            else if call.isOutgoing { state = .offhook }
            else { state = .ringing }
            self?.corePtr?.onCallStateChanged(state: state, phoneNumber: nil)
        }
        callObserver.setDelegate(callObserverDelegate, queue: nil)
    }

    // ── Internal helpers ─────────────────────────────────────────────────

    /// Snapshot accessor for `core` under lock — the property is `weak`
    /// so the read needs the lock to avoid a torn pointer.
    private var corePtr: RealMetaCore? {
        lock.lock(); defer { lock.unlock() }
        return core
    }

    private func snapshotDeviceSession() -> MWDATCore.DeviceSession? {
        lock.lock(); defer { lock.unlock() }
        return deviceSession
    }

    private func takeDeviceSession() -> MWDATCore.DeviceSession? {
        lock.lock(); defer { lock.unlock() }
        let s = deviceSession
        deviceSession = nil
        currentDevice = nil
        return s
    }

    private func snapshotStreamSession() -> MWDATCamera.Stream? {
        lock.lock(); defer { lock.unlock() }
        return streamSession
    }

    private func takeStreamSession() -> MWDATCamera.Stream? {
        lock.lock(); defer { lock.unlock() }
        let s = streamSession
        streamSession = nil
        streamCodec = nil
        return s
    }

    private func takeSttHandle() -> SttEngineHandle? {
        lock.lock(); defer { lock.unlock() }
        let h = sttHandle
        sttHandle = nil
        sttEngine = nil
        return h
    }

    private func clearVideoCapture(requestId: String) {
        lock.lock()
        if videoCaptureRequestId == requestId {
            videoCaptureTask = nil
            videoCaptureRequestId = nil
        }
        lock.unlock()
    }

    private func cancelDeviceSessionTokens() {
        lock.lock()
        let s = deviceSessionStateToken
        let e = deviceSessionErrorToken
        deviceSessionStateToken = nil
        deviceSessionErrorToken = nil
        lock.unlock()
        Task {
            if let s = s { await s.cancel() }
            if let e = e { await e.cancel() }
        }
    }

    private func cancelStreamSessionTokens() {
        lock.lock()
        let s = streamSessionStateToken
        let e = streamSessionErrorToken
        streamSessionStateToken = nil
        streamSessionErrorToken = nil
        lock.unlock()
        Task {
            if let s = s { await s.cancel() }
            if let e = e { await e.cancel() }
        }
    }

    private func cancelMWDATTokens() {
        cancelDeviceSessionTokens()
        cancelStreamSessionTokens()
    }

    /// Open (or reuse) a stream session at the given frame rate for video.
    /// Used by both `captureVideo` and `videoFramesStream`. Lazy — the
    /// existing iOS shell opened the stream session on demand from these
    /// paths, not at `connect()` time. Preserved.
    private func ensureStreamSessionForVideo(frameRate: UInt) async -> MWDATCamera.Stream? {
        // Video runs on the SAME .raw stream as photo — a codec swap (.raw↔.hvc1)
        // collapses the WARP channel (dogfood: frame-grab then video errored). .raw
        // frames are decoded pixel buffers; VideoCaptureSession ENCODES them to HEVC.
        switch await ensureStreamArmed(codec: .raw, resolution: .medium, frameRate: frameRate) {
        case .streaming(let s): return s
        case .paused, .failed: return nil
        }
    }

    // ── Static helpers ───────────────────────────────────────────────────

    private static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true)
    }

    private static func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private static func mapResolution(_ r: Resolution) -> MWDATCamera.StreamingResolution {
        switch r {
        case .low: return .low
        case .medium: return .medium
        case .high: return .medium // MWDATCamera high not exposed in 0.6
        }
    }

    private static func photoFormat(_ pf: PhotoFormat) -> MWDATCamera.PhotoCaptureFormat {
        switch pf {
        case .heic: return .heic
        case .jpeg: return .jpeg
        }
    }

    private static func mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalSeverity? {
        switch state {
        case .nominal: return nil
        case .fair: return .light
        case .serious: return .moderate
        case .critical: return .severe
        @unknown default: return nil
        }
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

    // Capture-error copy comes from the CORE's exported captureErrorMessage
    // (types/errors.rs — one vocabulary, both platforms; the private Swift
    // duplicate here went stale the moment the core gained StreamPaused and
    // broke the iOS-platform build for 6 days unnoticed).

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

    private static func writeTempFile(data: Data, ext: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = dir.appendingPathComponent("mwdat-\(UUID().uuidString).\(ext)")
        try? data.write(to: url)
        return url
    }
}

// ── Bridge-local helper types ────────────────────────────────────────────

/// Indirection so `SharedAudioInput`'s capture-by-value closures can flip
/// `audioSessionActive` on the bridge without retaining it. The bridge
/// registers a `weak self`-style listener via `attach`; the
/// `SharedAudioInput` callbacks call `set`. Lock-protected.
private final class AudioFlagHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: ((Bool) -> Void)?

    func attach(_ listener: @escaping (Bool) -> Void) {
        lock.lock(); self.listener = listener; lock.unlock()
    }

    func set(_ active: Bool) {
        lock.lock(); let l = listener; lock.unlock()
        l?(active)
    }
}

/// Fire-once latch for the photo capture's "next photoDataPublisher event
/// or 10s timeout" race. Mirrors the pattern the existing iOS shell used
/// before the rewire.
private final class OneShotBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func resume(with value: T?, continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        let already = done
        done = true
        lock.unlock()
        if already { return }
        continuation.resume(returning: value)
    }
}

/// Holds the `SharedAudioInput` subscription id so the stream's
/// `onTermination` closure can unsubscribe without sharing actor-isolated
/// state directly.
private actor AudioSubscriptionBox {
    private var subscriptionId: UUID?
    func set(_ id: UUID) { subscriptionId = id }
    func id() -> UUID? { subscriptionId }
}

/// Sendable Error wrapper for `String(describing: error)` payloads coming
/// out of MWDAT and friends. The Phase 2.0 `transportError.platformError`
/// factory accepts any `Error`; this box matches the existing iOS shape.
struct PlatformErrorBox: Error, Sendable {
    let message: String
    init(error: Error) { self.message = String(describing: error) }
}

/// CXCallObserverDelegate retains its delegate via setDelegate(_, queue:),
/// so an `@objc` class is required. Hoisted out of the bridge so the
/// `weak self` capture in the closure stays clean.
final class CallObserverDelegate: NSObject, CXCallObserverDelegate, @unchecked Sendable {
    var onCall: (@Sendable (CXCall) -> Void)?

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        onCall?(call)
    }
}

#endif // os(iOS)
