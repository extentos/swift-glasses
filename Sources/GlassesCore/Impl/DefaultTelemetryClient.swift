import Foundation

// Runtime telemetry client — batches events, POSTs to the ingest endpoint,
// retries with exponential backoff on failure.
// Spec: docs/mcp/TELEMETRY.md § Ingest pipeline
//
// Wire format parity with Android: library events authenticate via
// (appId, anonymousDeviceId) headers. Same JSON envelope, same properties
// scalar-only rule, same 30s/50-event flush, same 500-cap retry queue
// with 7d TTL and 30s/2m/10m/1h backoff.
//
// Persistence note (MVP): retry queue is in-memory. A process restart drops
// in-flight events. Matches the rest of the MVP backend's in-memory posture.
// Also: iOS ships un-gzipped payloads at MVP — the backend accepts both
// `content-encoding: gzip` and identity. Gzip on iOS is a follow-up.

final class DefaultTelemetryClient: TelemetryClient, @unchecked Sendable {
    let consent: Bool

    private let lock = NSLock()
    private var pending: [TelemetryEventRecord] = []
    private var retry: [TelemetryEventRecord] = []
    private var userSegment: String?

    private let context: TelemetryIngestContext
    private let poster: TelemetryPosting
    private let nowMs: @Sendable () -> Int64
    private var flushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init(
        consent: Bool,
        context: TelemetryIngestContext,
        poster: TelemetryPosting? = nil,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.consent = consent
        self.context = context
        self.poster = poster ?? URLSessionTelemetryPoster(endpoint: context.endpoint)
        self.nowMs = nowMs
        if consent {
            self.flushTask = Task.detached(priority: .background) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(DefaultTelemetryClient.flushIntervalMs) * 1_000_000)
                    await self?.flush(reason: "interval")
                }
            }
        }
    }

    // Phase-1 back-compat shim so existing `DefaultTelemetryClient(consent:)`
    // call sites still compile during the Slice 1 rollout. When
    // DefaultExtentosGlasses is migrated to pass a context, this can go.
    convenience init(consent: Bool) {
        self.init(
            consent: consent,
            context: TelemetryIngestContext(
                endpoint: URL(string: "https://api.extentos.com/api/telemetry/events")!,
                appId: nil,
                accountId: nil,
                installId: nil,
                anonymousDeviceId: AnonymousDeviceId.resolve(),
                libVersion: LibraryVersion.version,
                vendor: "meta_rayban",
                platform: "ios",
                osVersion: currentOSVersion(),
                deviceModel: currentDeviceModel()
            ),
            poster: nil
        )
    }

    deinit {
        flushTask?.cancel()
        retryTask?.cancel()
    }

    func setUserSegment(_ segment: String?) {
        lock.lock(); defer { lock.unlock() }
        userSegment = segment
    }

    func trackEvent(name: String, properties: [String: JSONValue]) {
        guard consent else { return }
        let record = buildRecord(category: "custom", name: name, properties: properties)
        enqueue(record)
    }

    func emitBaseline(name: String, properties: [String: JSONValue]) {
        guard consent else { return }
        let record = buildRecord(category: "runtime", name: name, properties: properties)
        enqueue(record)
    }

    func snapshotCounts() -> [String: Int] {
        // Kept for back-compat with the Phase-1 test surface. With the new
        // implementation we don't maintain per-event counters — tests now
        // inspect pending/retry via the injected poster.
        return [:]
    }

    private func buildRecord(category: String, name: String, properties: [String: JSONValue]) -> TelemetryEventRecord {
        let sanitized = sanitizeProperties(properties)
        lock.lock()
        let segment = userSegment
        lock.unlock()
        return TelemetryEventRecord(
            eventId: "tev_" + randomHex(16),
            timestamp: isoTimestamp(nowMs()),
            category: category,
            name: name,
            userSegment: segment,
            properties: sanitized,
            enqueuedAtMs: nowMs()
        )
    }

    private func enqueue(_ record: TelemetryEventRecord) {
        lock.lock()
        pending.append(record)
        let shouldFlush = pending.count >= DefaultTelemetryClient.flushBatchSize
        lock.unlock()
        if shouldFlush {
            Task.detached(priority: .background) { [weak self] in
                await self?.flush(reason: "batch")
            }
        }
    }

    func flush(reason: String) async {
        let batch: [TelemetryEventRecord] = lock.withLock {
            let drained = pending
            pending.removeAll(keepingCapacity: true)
            return drained
        }
        if batch.isEmpty { return }
        let ok = await poster.post(events: batch, context: context)
        if !ok {
            lock.withLock {
                for e in batch {
                    retry.append(e)
                    while retry.count > DefaultTelemetryClient.retryMax {
                        retry.removeFirst()
                    }
                }
            }
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        let alreadyRunning: Bool = lock.withLock {
            if let existing = retryTask, !existing.isCancelled { return true }
            return false
        }
        if alreadyRunning { return }
        retryTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                let delayMs = DefaultTelemetryClient.backoffMs(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                let batch: [TelemetryEventRecord]? = self.lock.withLock {
                    let cutoff = self.nowMs() - DefaultTelemetryClient.retryTtlMs
                    while let first = self.retry.first, first.enqueuedAtMs < cutoff {
                        self.retry.removeFirst()
                    }
                    if self.retry.isEmpty { return nil }
                    let drained = self.retry
                    self.retry.removeAll(keepingCapacity: true)
                    return drained
                }
                guard let batch = batch else { return }
                let ok = await self.poster.post(events: batch, context: self.context)
                if ok {
                    attempt = 0
                } else {
                    attempt += 1
                    self.lock.withLock {
                        for e in batch {
                            self.retry.append(e)
                            while self.retry.count > DefaultTelemetryClient.retryMax {
                                self.retry.removeFirst()
                            }
                        }
                    }
                }
            }
        }
    }

    static let flushIntervalMs: Int64 = 30_000
    static let flushBatchSize: Int = 50
    static let retryMax: Int = 500
    static let retryTtlMs: Int64 = 7 * 24 * 60 * 60 * 1000

    static func backoffMs(attempt: Int) -> Int64 {
        switch attempt {
        case 0: return 30_000
        case 1: return 2 * 60_000
        case 2: return 10 * 60_000
        default: return 60 * 60_000
        }
    }
}

struct TelemetryIngestContext: Sendable {
    let endpoint: URL
    let appId: String?
    let accountId: String?
    let installId: String?
    let anonymousDeviceId: String
    let libVersion: String
    let vendor: String?
    let platform: String
    let osVersion: String?
    let deviceModel: String?
    /// Wire form: "development" | "beta" | "production". Default "development".
    let environment: String
    /// false → backend flags this event as not includable in vendor aggregates.
    let dataSharingConsent: Bool

    init(
        endpoint: URL,
        appId: String?,
        accountId: String?,
        installId: String?,
        anonymousDeviceId: String,
        libVersion: String,
        vendor: String?,
        platform: String,
        osVersion: String?,
        deviceModel: String?,
        environment: String = "development",
        dataSharingConsent: Bool = true
    ) {
        self.endpoint = endpoint
        self.appId = appId
        self.accountId = accountId
        self.installId = installId
        self.anonymousDeviceId = anonymousDeviceId
        self.libVersion = libVersion
        self.vendor = vendor
        self.platform = platform
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.environment = environment
        self.dataSharingConsent = dataSharingConsent
    }
}

struct TelemetryEventRecord: Sendable {
    let eventId: String
    let timestamp: String
    let category: String
    let name: String
    let userSegment: String?
    let properties: [String: JSONValue]
    let enqueuedAtMs: Int64
}

protocol TelemetryPosting: Sendable {
    func post(events: [TelemetryEventRecord], context: TelemetryIngestContext) async -> Bool
}

final class URLSessionTelemetryPoster: TelemetryPosting, @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    /// Optional Layer 3 attestation client. When non-nil and the actor's
    /// getJWT() returns a token, the poster attaches Authorization: Bearer
    /// to attest the post.
    private let attestClient: AttestClient?

    init(endpoint: URL, attestClient: AttestClient? = nil, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.attestClient = attestClient
        self.session = session
    }

    func post(events: [TelemetryEventRecord], context: TelemetryIngestContext) async -> Bool {
        guard !events.isEmpty else { return true }
        let json = TelemetryJson.encodeBatch(events: events, context: context)
        guard let body = json.data(using: .utf8) else { return false }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // MVP: no gzip from iOS. Backend accepts identity encoding.
        if let appId = context.appId, !appId.isEmpty {
            request.setValue(appId, forHTTPHeaderField: "x-extentos-app-id")
        }
        request.setValue(context.anonymousDeviceId, forHTTPHeaderField: "x-extentos-anonymous-device-id")
        if let installId = context.installId, !installId.isEmpty {
            request.setValue(installId, forHTTPHeaderField: "x-extentos-install-id")
        }
        if let attest = attestClient, let jwt = await attest.getJWT() {
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 10
        do {
            let (_, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

enum TelemetryJson {
    static func encodeBatch(events: [TelemetryEventRecord], context: TelemetryIngestContext) -> String {
        var s = "["
        for (i, e) in events.enumerated() {
            if i > 0 { s += "," }
            s += encodeEvent(e, context: context)
        }
        s += "]"
        return s
    }

    private static func encodeEvent(_ e: TelemetryEventRecord, context ctx: TelemetryIngestContext) -> String {
        var parts: [String] = []
        parts.append("\"eventId\":\"\(escape(e.eventId))\"")
        parts.append("\"timestamp\":\"\(escape(e.timestamp))\"")
        parts.append("\"category\":\"\(escape(e.category))\"")
        parts.append("\"name\":\"\(escape(e.name))\"")
        parts.append("\"libVersion\":\"\(escape(ctx.libVersion))\"")
        parts.append("\"vendor\":\(ctx.vendor.map { "\"\(escape($0))\"" } ?? "null")")
        parts.append("\"platform\":\"\(escape(ctx.platform))\"")
        parts.append("\"osVersion\":\(ctx.osVersion.map { "\"\(escape($0))\"" } ?? "null")")
        parts.append("\"deviceModel\":\(ctx.deviceModel.map { "\"\(escape($0))\"" } ?? "null")")
        parts.append("\"userSegment\":\(e.userSegment.map { "\"\(escape($0))\"" } ?? "null")")
        parts.append("\"environment\":\"\(escape(ctx.environment))\"")
        parts.append("\"dataSharingConsent\":\(ctx.dataSharingConsent ? "true" : "false")")
        parts.append("\"properties\":\(encodeProperties(e.properties))")
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func encodeProperties(_ props: [String: JSONValue]) -> String {
        var parts: [String] = []
        // Stable key order helps deterministic assertions in tests.
        for k in props.keys.sorted() {
            let v = props[k]!
            parts.append("\"\(escape(k))\":\(encodeValue(v))")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func encodeValue(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d.isNaN || d.isInfinite { return "null" }
            return String(d)
        case .string(let s): return "\"\(escape(s))\""
        // Non-scalars — shouldn't reach us after sanitize, but stay safe.
        case .array, .object: return "null"
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if let scalar = c.unicodeScalars.first, scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.append(c)
                }
            }
        }
        return out
    }
}

private func sanitizeProperties(_ input: [String: JSONValue]) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for (k, v) in input {
        switch v {
        case .null, .bool, .int, .double, .string:
            out[k] = v
        case .array, .object:
            continue
        }
    }
    return out
}

private func isoTimestamp(_ ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.string(from: date)
}

private func randomHex(_ n: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: (n + 1) / 2)
    for i in 0..<bytes.count {
        bytes[i] = UInt8.random(in: 0...255)
    }
    return bytes.map { String(format: "%02x", $0) }.joined().prefix(n).lowercased()
}

private func currentOSVersion() -> String? {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

private func currentDeviceModel() -> String? {
    // UIDevice.current.model is MainActor-isolated in Swift 6. Leaving nil
    // for MVP; developer-observed breakdowns care about deviceModel from
    // stream.started / app.initialized properties, not the top-level field.
    return nil
}

enum AnonymousDeviceId {
    private static let key = "com.extentos.glasses.anonymousDeviceId"

    static func resolve() -> String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = "dev_" + randomHex(20)
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }
}
