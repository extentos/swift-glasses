import Foundation

public struct ExtentosConfig: Sendable {
    public var appId: String?
    public var accountId: String?
    public var transport: TransportChoice
    public var progressiveResponse: ProgressiveResponseConfig
    public var logLevel: LogLevel
    public var externalTaskGroup: (any TaskGroupHandle)?
    public var interceptors: [any ExtentosInterceptor]
    public var debug: Bool
    public var telemetryConsent: Bool
    /// Whether this app's events can be aggregated into the cross-account
    /// datasets Extentos sells to glasses-vendor businesses (CCPA "sale").
    /// Default: `true`. Setting to `false` is a developer-level Do-Not-Sell —
    /// the developer's own analytics dashboard keeps working, but their data
    /// is excluded from vendor aggregates. See content/docs/resources/security.mdx.
    ///
    /// Distinct from `telemetryConsent`: telemetry off → no events sent at all.
    /// `dataSharingConsent` off → events sent for the dev dashboard but flagged
    /// to skip vendor aggregation.
    public var dataSharingConsent: Bool
    /// Which environment this build represents. Default `.development` keeps
    /// debug-build noise out of production analytics by default. Production
    /// apps **must** set this to `.production` explicitly:
    ///
    ///     #if DEBUG
    ///     let env: ExtentosEnvironment = .development
    ///     #else
    ///     let env: ExtentosEnvironment = .production
    ///     #endif
    ///
    /// Beta channels (TestFlight) should set `.beta`.
    /// Routing impact: backend uses this to decide whether events land in the
    /// dev project, the prod-attested bucket, or the beta bucket.
    public var environment: ExtentosEnvironment
    /// Override the default telemetry ingest endpoint
    /// (`https://api.extentos.com/api/telemetry/events`).
    /// Nil → uses the production endpoint.
    public var telemetryEndpoint: URL?
    public var premiumVoice: PremiumVoiceConfig
    /// Optional override for bonded-Meta-device detection during `.auto`
    /// transport resolution. MWDAT 0.6 exposes no public service UUID for
    /// `CBCentralManager.retrieveConnectedPeripherals`, so host apps that
    /// want the Auto chain to pick `.realMeta` ahead of `.localSim` can
    /// supply this closure. Defaults to nil → treated as "no bonded device."
    public var hasBondedMetaDevice: (@Sendable () -> Bool)?

    /// The app's declared capability footprint — drives the connection
    /// page's capability tiles ("the app decides which tiles exist; the
    /// device decides which are lit"). Emitted by generateConnectionModule
    /// from the scaffold's `capabilities`; empty = no tiles section.
    public var usedCapabilities: [DeclaredCapability]

    public init(
        appId: String? = nil,
        accountId: String? = nil,
        transport: TransportChoice = .auto,
        progressiveResponse: ProgressiveResponseConfig = .default,
        logLevel: LogLevel = .warn,
        externalTaskGroup: (any TaskGroupHandle)? = nil,
        interceptors: [any ExtentosInterceptor] = [],
        debug: Bool = false,
        telemetryConsent: Bool = true,
        dataSharingConsent: Bool = true,
        environment: ExtentosEnvironment = .development,
        telemetryEndpoint: URL? = nil,
        premiumVoice: PremiumVoiceConfig = .none,
        hasBondedMetaDevice: (@Sendable () -> Bool)? = nil,
        usedCapabilities: [DeclaredCapability] = []
    ) {
        self.usedCapabilities = usedCapabilities
        self.appId = appId
        self.accountId = accountId
        self.transport = transport
        self.progressiveResponse = progressiveResponse
        self.logLevel = logLevel
        self.externalTaskGroup = externalTaskGroup
        self.interceptors = interceptors
        self.debug = debug
        self.telemetryConsent = telemetryConsent
        self.dataSharingConsent = dataSharingConsent
        self.environment = environment
        self.telemetryEndpoint = telemetryEndpoint
        self.premiumVoice = premiumVoice
        self.hasBondedMetaDevice = hasBondedMetaDevice
    }
}

// `ExtentosEnvironment` → migrated to extentos-core; its `wireValue` property is
// re-added as an extension in MigratedCoreTypes.swift (uniffi enums carry no
// custom members). See MigratedCoreTypes.swift.

public enum TransportChoice: Sendable {
    case auto
    case realMeta
    case simulated(Simulated)

    public enum Simulated: Sendable {
        case browser(url: URL)
        case local
    }
}

public enum ProgressiveResponseConfig: Sendable {
    case `default`
    case off
    case custom(phrase: String)
    case earcon(resource: URL)
}

public enum LogLevel: Int, Sendable {
    case verbose, debug, info, warn, error
}

public protocol ExtentosInterceptor: Sendable {
    func observe(_ event: InterceptedEvent) async
}

public struct InterceptedEvent: Sendable {
    public let name: String
    public let payload: JSONValue
    public let timestampMs: Int64
    public init(name: String, payload: JSONValue, timestampMs: Int64) {
        self.name = name
        self.payload = payload
        self.timestampMs = timestampMs
    }
}

public protocol TaskGroupHandle: Sendable {
    func addTask(_ body: @escaping @Sendable () async -> Void)
}

public enum PremiumVoiceConfig: Sendable {
    case none
    case elevenLabs(apiKey: String, voiceId: String?)
    case azureNeural(subscriptionKey: String, region: String, voiceName: String?)
    case playHt(apiKey: String, userId: String, voiceId: String?)
    case custom(
        providerId: String,
        credentials: [String: String],
        invoke: @Sendable (_ text: String, _ credentials: [String: String]) async throws -> Data
    )
}
