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
            // Resolved from the transport at ENCODE time, mirroring Android.
            // Was the literal "meta_rayban" — a token Android retired on
            // 2026-07-24 and iOS was missed on. The backend had been silently
            // normalizing it ever since (telemetry-store.ts), so the warehouse
            // looked correct while the client kept sending a retired value.
            // Falls back to "meta" exactly as Android does when the transport
            // does not know yet.
            vendor: { [transport] in transport.currentVendorId() ?? "meta" },
            platform: "ios",
            osVersion: { let v = ProcessInfo.processInfo.operatingSystemVersion
                         return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }(),
            // The CONNECTED GLASSES model, not the phone. Was hardcoded nil,
            // which is why iOS never reported which glasses were used and the
            // vendor breakdown was Android-only. The fact was never missing —
            // the Rust core has held it all along (`device_model_id`), and only
            // one shell was reading it.
            deviceModel: { [transport] in transport.currentDeviceModelId() },
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
        // The source comes from the CALLER now. It used to be hardcoded .ui
        // here, which reported every assistant- and automation-driven toggle
        // change as a user tap.
        self._toggles = DefaultToggleClient(onChange: { key, oldVal, newVal, source in
            Task {
                await togglesLogger.emit(
                    .toggleChanged(key: key, oldValue: oldVal, newValue: newVal, source: source))
            }
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
        // register here at assistant start (Phase 2); code registrations
        self._audio = DefaultAudioClient(transport: transport, toggles: _toggles, onStreamLifecycle: bridge)
        self._runtime = DefaultRuntimeClient(eventLogger: eventLogger)
        // VoiceScope gating needs the live assistant state, but the voice client
        // is built before the assistant exists. Same shape as Kotlin's
        // AtomicReference: a shared probe handed over now and pointed at the
        // assistant once it is constructed.
        let assistantProbe = AssistantStateProbe()
        self._voice = DefaultVoiceClient(
            audio: _audio,
            currentAssistantState: { assistantProbe.current() }
        )
        // D5b: hosted-media delivery for the local-media display roots. The
        // asset→copy registry is core-owned (shared with Android); this wires the
        // upload/delete IO and persists the snapshot across launches.
        let hostedMedia = HostedMediaStore(file: HostedMediaStore.defaultFile())
        let mediaEnv = effectiveEnvironment
        self._display = DefaultDisplayClient(
            transport: transport,
            mediaDelivery: HttpMediaDelivery(
                registry: hostedMedia.registry,
                persist: { hostedMedia.persist() },
                uploader: HttpMediaUploader(
                    endpointFor: { kind in defaultDisplayMediaEndpoint(mediaEnv, kind) },
                    installId: nil
                )
            )
        )
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
            // Gateway bearer: the sim session token when simulating, otherwise
            // the baked project key — in EVERY environment, beta and production
            // included. This is correct. Do not "fix" it into an attest-JWT
            // lane; an earlier comment here promised exactly that and it was
            // rejected on the merits (RDQ 95/96, 2026-08-11).
            //
            // Two independent reasons, either one sufficient:
            //   1. Production could not obtain a JWT. Attestation is an upgrade
            //      available only where the platform gives it away, and it is
            //      not wired on iOS (the scaffold emits no App Attest
            //      entitlement, and app_attest_keys has never registered a
            //      single key). A JWT bearer here would be nil in production.
            //   2. Even with a JWT, this client sends NO x-extentos-project-key
            //      header — DefaultAssistantClient's `.gateway(...)` call omits
            //      it — so the backend could not attribute the session,
            //      attest JWTs carry no accountId, and the credit gate would
            //      refuse it as `billing_unattributed`.
            //
            // Android had the "correct-looking" precedence and it left its
            // production arm resolving to nil, so every app shipped to Play had
            // a dead assistant until 5bde088b; Android now matches THIS.
            // Backend view: gateway-auth.ts. If the header is ever added for
            // attribution parity, it is additive and does not change the bearer.
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

        // Every stored property is initialized by here, so `self` may escape:
        // point the probe at the assistant's live session state, which is what
        // VoiceScope gating reads on each dispatch.
        assistantProbe.bind { [weak self] in self?._assistant.activeSession?.state.current }

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
        // Profile is core-owned (capability/mod.rs), routed by VENDOR and MODEL.
        // This used to call metaCapabilityProfile unconditionally, which was
        // silently wrong the moment a second vendor shipped: a Brilliant Frame
        // was told it had a speaker it does not have. Android had the mirror-image
        // bug (vendor-routed, so a Halo reported no hardware at all); one
        // core-owned answer fixes both. Pre-handshake the transport may not know
        // its vendor, and the Meta floor is the original behaviour.
        deviceCapabilityProfile(
            // Literal rather than an enum: Swift has no `GlassesVendor` type
            // (Kotlin does). That asymmetry is a separate parity gap, tracked
            // with the rest of the iOS vendor-axis mirror.
            vendor: transport.currentVendorId() ?? "meta",
            modelId: transport.currentDeviceModelId(),
            displayCapable: transport.isDisplayCapable()
        )
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
