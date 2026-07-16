import Foundation

// Concrete ExtentosGlasses — the implementation returned by Extentos.create().
// Post pure-SDK pivot: no spec runtime, no FlowIO, no DefaultDebugClient,
// no DefaultExtensionsClient, no DefaultSpecStreamsClient, no
// RuntimeEventForwarder. The runtime client is just an EventLogger
// relay. Mirrors `android-library/.../core/ExtentosGlasses.kt` (current
// state on disk, post-pivot).

public final class DefaultExtentosGlasses: ExtentosGlasses, @unchecked Sendable {
    private let transport: any GlassesTransport
    private let eventLogger: EventLogger

    private let _connection: DefaultConnectionClient
    private let _camera: DefaultCameraClient
    private let _audio: DefaultAudioClient
    private let _soundRegistry: SoundRegistry
    private let _runtime: DefaultRuntimeClient
    private let _toggles: DefaultToggleClient
    private let _voice: DefaultVoiceClient
    private let _display: DefaultDisplayClient
    private let _usedCapabilities: [DeclaredCapability]
    private let _telemetry: DefaultTelemetryClient
    private let _observability: DefaultObservabilityClient
    private let _voiceBridge: VoiceTransportBridge?
    // Phase 4 / S1.M.11 — always-on assistant client; mirrors Android
    // `743d90c`. AssistantTransportBridge is non-nil only on BrowserSim.
    private let _assistant: DefaultAssistantClient
    private let _assistantBridge: AssistantTransportBridge?

    init(
        config: ExtentosConfig,
        transport: any GlassesTransport,
        chosen: TransportChosen,
        source: TransportSelectionSource
    ) {
        self.transport = transport
        self.eventLogger = EventLogger(capacity: 512)

        // Layer 2 pre-flight: reconcile the declared environment with what
        // the on-device classifier observes. Bulletproofs against a developer
        // who hardcodes .production but ships a DEBUG build — we downgrade
        // silently with a console warning rather than letting dev events
        // reach the production analytics stack.
        let classification = EnvironmentClassifier.classify()
        let reconciliation = reconcileEnvironment(
            declared: config.environment,
            classified: classification
        )
        let effectiveEnvironment = reconciliation.effective
        if let reason = reconciliation.mismatchReason {
            print("[Extentos] WARN: \(reason)")
        }

        // Hard endpoint isolation: .production routes to a separate Fly app +
        // Supabase project that only accepts prod-attested traffic. .beta and
        // .development share the dev backend (different Supabase project than
        // production); the environment column distinguishes them server-side.
        // See docs/TELEMETRY_PRODUCT_PLAN.md § Layer 1: Hard endpoint isolation.
        let defaultEndpoint: URL = {
            switch effectiveEnvironment {
            case .production:
                return URL(string: "https://prod.api.extentos.com/api/telemetry/events")!
            case .beta, .development:
                return URL(string: "https://api.extentos.com/api/telemetry/events")!
            }
        }()
        let telemetryEndpoint = config.telemetryEndpoint ?? defaultEndpoint
        // appId identifies the host app to the backend (telemetry identity,
        // attestation, assistant-config). Mirror Android's
        // `config.appId ?: applicationContext.packageName` fallback: default
        // to the bundle identifier so telemetry works without any plist key —
        // a nil appId makes the ingest endpoint reject every batch
        // (identity_required) and the app silently emits nothing.
        let effectiveAppId = config.appId ?? Bundle.main.bundleIdentifier
        let telemetryContext = TelemetryIngestContext(
            endpoint: telemetryEndpoint,
            appId: effectiveAppId,
            accountId: config.accountId,
            installId: nil,
            anonymousDeviceId: AnonymousDeviceId.resolve(),
            libVersion: LibraryVersion.version,
            vendor: "meta_rayban",
            platform: "ios",
            osVersion: { let v = ProcessInfo.processInfo.operatingSystemVersion
                         return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }(),
            deviceModel: nil,
            environment: effectiveEnvironment.wireValue,
            dataSharingConsent: config.dataSharingConsent
        )
        // Layer 3 attestation client — kicks off background attestation.
        // The poster reads its cached JWT before each post and attaches
        // Authorization: Bearer when present. First batch may go un-attested;
        // subsequent ones get the JWT once attestation completes.
        let attestClient = AttestClient(
            attestEndpoint: defaultAttestEndpoint(effectiveEnvironment),
            appId: effectiveAppId,
            anonymousDeviceId: AnonymousDeviceId.resolve(),
            effectiveEnvironment: effectiveEnvironment
        )
        if config.telemetryConsent {
            Task.detached(priority: .background) { [attestClient] in
                await attestClient.start()
            }
        }

        let poster = URLSessionTelemetryPoster(
            endpoint: telemetryEndpoint,
            attestClient: attestClient
        )
        self._telemetry = DefaultTelemetryClient(
            consent: config.telemetryConsent,
            context: telemetryContext,
            poster: poster
        )

        let togglesLogger = self.eventLogger
        self._toggles = DefaultToggleClient(onChange: { key, oldVal, newVal in
            Task { await togglesLogger.emit(.toggleChanged(key: key, oldValue: oldVal, newValue: newVal, source: .ui)) }
        })

        let initialUiState = ExtentosUiState(
            connection: .notRegistered,
            auth: .required,
            firmware: nil,
            deviceName: nil,
            capabilities: [],
            toggles: [],
            libraryVersion: LibraryVersion.version
        )
        self._connection = DefaultConnectionClient(transport: transport, initialUiState: initialUiState)

        let bridge = TelemetryBridge(
            telemetry: self._telemetry,
            eventLogger: eventLogger,
            connectionState: _connection.state,
            transportChosen: chosen
        )

        self._camera = DefaultCameraClient(transport: transport, toggles: _toggles, onStreamLifecycle: bridge)
        // One shared named-sound registry (Rust core) — dashboard sounds
        // register here at assistant start (Phase 2); code registrations
        // via audio.registerSound overwrite (code > dashboard).
        let soundRegistry = SoundRegistry()
        self._soundRegistry = soundRegistry
        self._audio = DefaultAudioClient(transport: transport, toggles: _toggles, sounds: soundRegistry, onStreamLifecycle: bridge)
        self._runtime = DefaultRuntimeClient(eventLogger: eventLogger)
        self._voice = DefaultVoiceClient(audio: _audio)
        self._display = DefaultDisplayClient(transport: transport)
        self._usedCapabilities = config.usedCapabilities
        self._observability = DefaultObservabilityClient(transport: transport)

        // Phase 4 / S1.M.11 — assistant runtime is always-on (no model
        // load cost, the OpenAI WebSocket only opens on session.start()).
        // Lifecycle events flow through eventLogger as
        // RuntimeEvent.assistant and through the sim event-log via
        // AssistantTransportBridge (BrowserSim only). Mirrors Android
        // `743d90c`.
        let assistantEventLogger = self.eventLogger
        self._assistant = DefaultAssistantClient(
            audio: _audio,
            transport: transport,
            // Gateway bearer: the sim handshake token (dev). The attest-JWT
            // lane (beta/prod) lands with Phase-F device attestation.
            // Auth precedence (Android parity): sim token (simulator) ->
            // baked project key on a non-sim debug build (dogfood on real
            // glasses, dev-tier Bearer) -> attest JWT (beta/prod; Phase F).
            gatewayToken: { [weak sim = transport as? BrowserSimTransport] in
                sim?.simGatewayToken
                    ?? (Bundle.main.infoDictionary?["EXTENTOSProjectKey"] as? String)
            },
            // Live-config fetch auth: the ATTEST JWT (nil in dev — the
            // route allows a missing bearer), NEVER the gateway token —
            // Android parity (Kotlin wires AttestClient.getJWT here).
            attestJWT: { [attestClient] in await attestClient.getJWT() },
            // Project identity for the dashboard live-config fetch —
            // same resolved appId as telemetry/attestation above.
            appId: effectiveAppId,
            voice: _voice,
            soundRegistry: soundRegistry,
            onAssistantEvent: { event in
                Task { await assistantEventLogger.emit(.assistant(event)) }
            }
        )
        if chosen == .browserSim {
            let bridge = AssistantTransportBridge(transport: transport, eventLogger: eventLogger)
            bridge.start()
            self._assistantBridge = bridge
        } else {
            self._assistantBridge = nil
        }

        // Browser-sim simulator UI subscribes to `app_voice_hints`
        // frames to render the click-to-fire Voice Commands panel.
        // The bridge no-ops on non-BrowserSim transports. Started here
        // so even pre-registered hints (e.g. a customer calling
        // glasses.voice.onPhrase before connect()) get an initial
        // snapshot once the WS is up.
        if chosen == .browserSim {
            let voiceBridge = VoiceTransportBridge(transport: transport, voice: _voice, connection: _connection)
            voiceBridge.start()
            self._voiceBridge = voiceBridge
        } else {
            self._voiceBridge = nil
        }

        // Record the resolved transport selection. Emitted as a `log` event
        // so it reaches the public runtime.events stream (transport.selected
        // is internal-only; log carries the same semantic payload).
        let chosenCopy = chosen
        let sourceCopy = source
        Task { [eventLogger] in
            await eventLogger.emit(.log(
                level: .info,
                message: "transport.selected",
                payload: .object([
                    "chosen": .string(chosenCopy.wireValue),
                    "source": .string(sourceCopy.wireValue),
                ])
            ))
        }

        // app.initialized — fires once per library init. Envelope already
        // carries libVersion/vendor/platform/osVersion/deviceModel, so the
        // properties map stays empty.
        self._telemetry.emitBaseline(name: "app.initialized", properties: [:])
    }

    public var connection: any ConnectionClient { _connection }
    public var camera: any CameraClient { _camera }
    public var audio: any AudioClient { _audio }
    public var runtime: any RuntimeClient { _runtime }
    public var toggles: any ToggleClient { _toggles }
    public var voice: any VoiceClient { _voice }
    public var display: any DisplayClient { _display }
    public var usedCapabilities: [DeclaredCapability] { _usedCapabilities }
    public var capabilities: DeviceCapabilitySet {
        // Profile is core-owned (capability/mod.rs).
        metaCapabilityProfile(displayCapable: transport.isDisplayCapable())
    }
    public var telemetry: any TelemetryClient { _telemetry }
    public var observability: any ObservabilityClient { _observability }
    public var assistant: any AssistantClient { _assistant }

    public func shutdown() async {
        _voiceBridge?.stop()
        _assistantBridge?.stop()
        await _assistant.stop()
        _voice.shutdown()
        await transport.shutdown()
        await eventLogger.drain()
    }

    public func handleUrl(_ url: URL) async -> Bool {
        await transport.handleUrl(url)
    }
}
