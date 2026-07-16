// Entry points and root protocol. See docs/mcp/LIBRARY_API_SWIFT.md.
import Foundation
#if canImport(Speech)
import Speech
#endif

public enum Extentos {
    /// Shared default instance. Uses `ExtentosConfig()` defaults on first access.
    public static func `default`() -> ExtentosGlasses {
        create(config: ExtentosConfig())
    }

    public static func create(config: ExtentosConfig) -> ExtentosGlasses {
        let (transport, chosen, source) = resolveTransport(config: config)
        return DefaultExtentosGlasses(
            config: config,
            transport: transport,
            chosen: chosen,
            source: source
        )
    }

    private static func resolveTransport(config: ExtentosConfig) -> (any GlassesTransport, TransportChosen, TransportSelectionSource) {
        // F51 multi-project bind fix: every BrowserSim construction
        // path threads the host app's bundle identifier so the backend
        // can bind on the composite `(install_id, platform_install_id)`
        // key. nil-safe — test harnesses without a main bundle id
        // legitimately omit the field and fall through to legacy
        // install-only matching. Mirrors Android's
        // `config.applicationContext?.packageName` thread.
        let hostAppPackageName = Bundle.main.bundleIdentifier
        switch config.transport {
        case .realMeta:
            return (buildRealMetaOrFallback(), .realMeta, .explicitConfig)
        case .simulated(.browser(let url)):
            return (
                BrowserSimTransport(
                    initialSessionUrl: url.absoluteString,
                    hostAppPackageName: hostAppPackageName
                ),
                .browserSim,
                .explicitConfig
            )
        case .simulated(.local):
            return (LocalSimTransport(), .localSim, .explicitConfig)
        case .auto:
            // Full Auto chain, mirroring Android's resolveAuto:
            //   1. Build-time injected session URL (Info.plist ExtentosSessionURL
            //      from the SPM build-phase script) + debug.
            //   2. EXTENTOS_SESSION_URL env var + debug.
            //   3. hasBondedMetaDevice closure → RealMeta.
            //   4. Track B+ pending socket — debug build with no URL,
            //      no bonded glasses. Library opens /ws/pending and waits
            //      for createSimulatorSession to bind it via the MCP
            //      localhost bridge.
            //   5. Fallback → LocalSim.
            if config.debug, let url = readBuildConfigSessionUrl(), !url.isEmpty {
                return (
                    BrowserSimTransport(
                        initialSessionUrl: url,
                        hostAppPackageName: hostAppPackageName
                    ),
                    .browserSim,
                    .buildConfig
                )
            }
            if config.debug, let url = ProcessInfo.processInfo.environment["EXTENTOS_SESSION_URL"], !url.isEmpty {
                return (
                    BrowserSimTransport(
                        initialSessionUrl: url,
                        hostAppPackageName: hostAppPackageName
                    ),
                    .browserSim,
                    .envVar
                )
            }
            if let detect = config.hasBondedMetaDevice, detect() {
                return (buildRealMetaOrFallback(), .realMeta, .bondedDevices)
            }
            if config.debug {
                let deviceInstallId = DeviceInstallStore.resolve()
                let transport = BrowserSimTransport(
                    initialSessionUrl: nil,
                    pendingMode: true,
                    deviceInstallId: deviceInstallId,
                    hostAppPackageName: hostAppPackageName
                )
                return (transport, .browserSim, .pairing)
            }
            // Rule 5 (iOS parity fix, dogfood 2026-07): a RELEASE build targets
            // real glasses. BrowserSim/LocalSim are debug-only. iOS cannot
            // enumerate BT bonds the way Android hasBondedMetaDeviceDefault does,
            // so a non-debug .auto build resolves to RealMeta and lets connect()
            // surface NoEligibleDevice when none are paired. (Was LocalSim: the
            // dogfood bug where a TestFlight/Release build silently used a fake sim.)
            return (buildRealMetaOrFallback(), .realMeta, .fallbackDefault)
        }
    }

    /// Looks up a session URL injected at build time via the Extentos SPM
    /// build-phase script. The script emits an `ExtentosSession` enum with
    /// `static let url: String?`. We read it via `Bundle.main` Info.plist
    /// keys as a fallback when the host app hasn't linked that file (e.g.,
    /// a direct library consumer running this code outside of a built app).
    /// Returns an expired URL as nil — same policy as Android's Gradle task.
    private static func readBuildConfigSessionUrl() -> String? {
        // PRIMARY: the standalone `extentos.session.plist` the scaffold's
        // SPM build phase copies into the app bundle on Debug builds —
        // this is the artifact generateConnectionModule actually ships
        // (dogfood finding #8: the reader previously checked only
        // Info.plist keys, so the URL-bake path was dead on iOS).
        // FALLBACK: the same keys merged into Info.plist directly.
        if let fileUrl = Bundle.main.url(forResource: "extentos.session", withExtension: "plist"),
           let data = try? Data(contentsOf: fileUrl),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
               as? [String: Any],
           let url = sessionUrl(from: dict) {
            return url
        }
        return sessionUrl(from: Bundle.main.infoDictionary ?? [:])
    }

    private static func sessionUrl(from dict: [String: Any]) -> String? {
        guard let url = dict["EXTENTOSSessionURL"] as? String, !url.isEmpty else {
            return nil
        }
        // An expired URL reads as nil — same policy as Android's Gradle task.
        if let expiresAt = dict["EXTENTOSSessionExpiresAt"] as? String,
           let expiryDate = ISO8601DateFormatter().date(from: expiresAt),
           expiryDate <= Date() {
            return nil
        }
        return url
    }

    private static func buildRealMetaOrFallback() -> any GlassesTransport {
        #if os(iOS)
        return RealMetaTransport()
        #else
        // MWDAT 0.6 has no macOS slice. Callers that force `.realMeta` on
        // macOS get a LocalSim fallback so Mac dev loops keep working.
        return LocalSimTransport()
        #endif
    }

    /// Proactively request Speech Recognition authorization. Safe to call
    /// before opening the connection page or before the first
    /// `transcriptions()` call — the `PlatformSttEngine` requests
    /// authorization on first use anyway, but host apps wanting to
    /// surface the prompt at a controlled moment (e.g. during onboarding)
    /// can call this directly.
    ///
    /// Host apps using `glasses.audio.transcriptions(config:)` need
    /// `NSSpeechRecognitionUsageDescription` declared in `Info.plist`
    /// regardless of when this call lands.
    public static func requestSpeechRecognitionAuthorization() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            #if canImport(Speech)
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
            #else
            cont.resume(returning: false)
            #endif
        }
    }
}

public protocol ExtentosGlasses: AnyObject, Sendable {
    var connection: any ConnectionClient { get }
    var camera: any CameraClient { get }
    var audio: any AudioClient { get }
    var runtime: any RuntimeClient { get }
    var toggles: any ToggleClient { get }
    /// Convenience surface over `audio.transcriptions()` that also
    /// announces "this app responds to phrase X" to the simulator + the
    /// in-app connection page. See `VoiceClient` for the contract.
    var voice: any VoiceClient { get }
    var telemetry: any TelemetryClient { get }
    /// Wrap BYOK AI calls so they appear in the simulator event log
    /// under the "ai" filter. See `ObservabilityClient` for the contract.
    var observability: any ObservabilityClient { get }

    /// Phase 4 — assistant runtime. The canonical voice-AI surface for
    /// v1.4.0+. No ONNX models loaded (end-to-end via OpenAI Realtime
    /// BYOK), so there's no cost to always exposing it. Call
    /// `glasses.assistant.setOpenAiApiKey(key)` then
    /// `try await glasses.assistant.start(provider: ...) { ... }`.
    /// See `AssistantClient`.
    var assistant: any AssistantClient { get }

    /// The native display surface (display-capable glasses only —
    /// `display.isAvailable` gates; calls degrade to silent no-ops on
    /// no-display devices).
    var display: any DisplayClient { get }

    /// The app's declared capability footprint (ExtentosConfig.usedCapabilities).
    var usedCapabilities: [DeclaredCapability] { get }

    /// Root-level connect convenience (Android parity — the generated
    /// bootstrap calls `glasses.connect()`). Equivalent to
    /// `connection.connect()`.
    @discardableResult
    func connect() async -> ExtentosResult<Void, ConnectError>

    /// Capability dial of the CONNECTED device: flat yes/no hardware facts.
    /// `display` flips live with the device (sim device switch / hardware
    /// pairing); camera/microphone/speaker are true across the current Meta
    /// lineup. ~95%% of capability branching belongs here.
    var capabilities: DeviceCapabilitySet { get }

    func shutdown() async

    /// Forwards a URL callback from the host app's `.onOpenURL` modifier to
    /// the underlying transport's registration handler. Returns `true` if
    /// the URL was consumed by the transport.
    ///
    /// Host app wiring:
    /// ```swift
    /// ContentView().onOpenURL { url in
    ///     Task { _ = await glasses.handleUrl(url) }
    /// }
    /// ```
    /// LocalSim and Phase 1 transports return `false` unconditionally.
    func handleUrl(_ url: URL) async -> Bool
}

public extension ExtentosGlasses {
    func handleUrl(_ url: URL) async -> Bool { false }

    @discardableResult
    func connect() async -> ExtentosResult<Void, ConnectError> {
        await connection.connect()
    }
}
