// Hosted-media delivery for the glasses display — the iOS half of DSP-23/24/29.
//
// Ported from android-library/.../impl/MediaDelivery.kt (D5b, flagged during the
// iOS Display phase and unported until now). Until this landed, `image(photo)`
// and `video(clip)` were Android-only and the iOS examples had to pass an
// http(s) URL themselves — a gap the docs described as a platform difference.
// It never was one: the glasses fetch http(s) on either platform, and the hard
// part (the asset→copy registry and its keying) is core-owned and shared.
//
// Why it exists at all: the glasses load media only from an http(s) URL over
// their own Wi-Fi. `data:` / `file:` are rejected and the phone never proxies
// bytes, so a locally-captured asset must become a hosted copy first.
//
// Split, mirroring Kotlin: HostedMediaRegistry (Rust core) owns the state and
// the keying so both platforms agree on "the same asset"; this shell drives the
// upload/delete IO and persists the registry snapshot.
import Foundation

/// The local-media kinds the SDK hosts for the lens. Picks the backend
/// endpoint/bucket (`/api/display/{kind}`) and the upload content-type.
enum MediaKind: String, Sendable {
    case video
    case image
}

/// Hosted-media delivery endpoint per kind. Operational channel → always
/// api.extentos.com; the host is resolved in the Rust core, shared with Android.
func defaultDisplayMediaEndpoint(_ env: ExtentosEnvironment, _ kind: MediaKind) -> String {
    "https://\(endpointHost(channel: .operational, env: env))/api/display/\(kind.rawValue)"
}

/// Resolves a locally-captured asset to a fetchable https URL, and tears that
/// hosted copy down when the source is deleted.
protocol MediaDelivery: Sendable {
    /// Upload `uri`'s bytes (or reuse its hosted copy) and return a fetchable
    /// URL, or nil if it can't be hosted.
    func hostedUrl(_ uri: String, kind: MediaKind) async -> String?

    /// Tear down `uri`'s hosted copy — its source is being deleted. Idempotent.
    func forget(_ uri: String, kind: MediaKind) async

    /// Whether `uri` already has a hosted copy on record — an in-memory registry
    /// peek, no IO, kind-agnostic.
    func isHosted(_ uri: String) -> Bool
}

/// The HTTP to the backend, behind a seam so the dedup/teardown orchestration
/// stays testable without a network.
protocol MediaUploader: Sendable {
    func upload(bytes: Data, contentType: String, kind: MediaKind) async -> HostedAsset?
    func delete(id: String, kind: MediaKind) async
}

/// Serializes per-asset uploads so two concurrent shows of the SAME asset upload
/// once. A double upload orphans a copy — the DSP-24 bug class. Kotlin uses a
/// per-key Mutex; an actor holding one continuation queue per key is the Swift
/// equivalent.
actor SingleFlight {
    private var inFlight: [String: Task<String?, Never>] = [:]

    func run(_ key: String, _ work: @escaping @Sendable () async -> String?) async -> String? {
        if let existing = inFlight[key] { return await existing.value }
        let task = Task(operation: work)
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }
}

/// Orchestrates hosted-media delivery over the core registry — shared by video
/// AND photo.
///
/// - `hostedUrl`: registry hit → reuse (no re-upload); miss → single-flight
///   upload, record the returned {id, url} (retaining the delete handle),
///   persist.
/// - `forget`: evict + DELETE the hosted copy by its retained id, persist.
final class HttpMediaDelivery: MediaDelivery {
    private let registry: HostedMediaRegistry
    private let persist: @Sendable () -> Void
    private let uploader: MediaUploader
    private let single = SingleFlight()

    init(registry: HostedMediaRegistry, persist: @escaping @Sendable () -> Void, uploader: MediaUploader) {
        self.registry = registry
        self.persist = persist
        self.uploader = uploader
    }

    func hostedUrl(_ uri: String, kind: MediaKind) async -> String? {
        let key = hostedMediaKey(uri: uri)
        // Fast path: a hosted copy already on record (this session OR a prior one
        // re-seeded from the persisted snapshot) — reuse it, no upload.
        if let hit = registry.lookup(key: key) { return hit.url }

        let registry = self.registry
        let uploader = self.uploader
        let persist = self.persist
        return await single.run(key) {
            // Re-check inside the flight: a concurrent caller may have just uploaded.
            if let hit = registry.lookup(key: key) { return hit.url }
            guard let bytes = await Self.loadBytes(uri, kind) else { return nil }
            guard let hosted = await uploader.upload(
                bytes: bytes,
                contentType: Self.contentType(uri, kind),
                kind: kind
            ) else { return nil }
            registry.record(key: key, hosted: hosted)
            persist()
            return hosted.url
        }
    }

    func forget(_ uri: String, kind: MediaKind) async {
        // Never hosted → no-op, so a source deleted before it was ever shown costs
        // nothing.
        guard let hosted = registry.forget(key: hostedMediaKey(uri: uri)) else { return }
        persist()
        await uploader.delete(id: hosted.id, kind: kind)
    }

    func isHosted(_ uri: String) -> Bool {
        registry.lookup(key: hostedMediaKey(uri: uri)) != nil
    }

    // Per-kind byte load + content-type — the ONLY places the two kinds diverge.
    // Both handle data: and file:// uris; the content-type drives the backend
    // bucket's allow-list.
    private static func loadBytes(_ uri: String, _ kind: MediaKind) async -> Data? {
        await LocalMediaBytes.load(uri)
    }

    private static func contentType(_ uri: String, _ kind: MediaKind) -> String {
        switch kind {
        case .video: return "video/mp4"
        case .image: return LocalMediaBytes.mediaType(uri) ?? "image/jpeg"
        }
    }
}

/// Byte loading for local media uris. Android has this on its `Photos` / `Videos`
/// helpers; iOS ships only `Photo.loadImage()`, so the raw-bytes path lives here
/// rather than re-encoding a decoded image (which would recompress the capture).
enum LocalMediaBytes {
    static func load(_ uri: String) async -> Data? {
        guard let url = URL(string: uri) else { return nil }
        switch url.scheme {
        case "file":
            return await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
        case "data":
            // data:<mediatype>[;base64],<payload>
            let s = url.absoluteString
            guard let comma = s.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(s[s.index(after: comma)...]))
            else { return nil }
            return data
        default:
            return nil
        }
    }

    /// The declared media type of a `data:` uri, so an image uploads under the
    /// type it actually is. nil for file: uris — the caller falls back per kind.
    static func mediaType(_ uri: String) -> String? {
        guard uri.hasPrefix("data:"),
              let semi = uri.firstIndex(where: { $0 == ";" || $0 == "," })
        else { return nil }
        let t = String(uri[uri.index(uri.startIndex, offsetBy: 5)..<semi])
        return t.isEmpty ? nil : t
    }
}

/// `MediaUploader` backed by the Extentos backend, which mediates storage — no
/// storage credentials in the SDK. `installId` only tags attribution; it never
/// gates.
final class HttpMediaUploader: MediaUploader {
    private let endpointFor: @Sendable (MediaKind) -> String
    private let installId: String?
    private let session: URLSession

    init(endpointFor: @escaping @Sendable (MediaKind) -> String, installId: String?, session: URLSession = .shared) {
        self.endpointFor = endpointFor
        self.installId = installId
        self.session = session
    }

    func upload(bytes: Data, contentType: String, kind: MediaKind) async -> HostedAsset? {
        guard let url = URL(string: endpointFor(kind)) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let installId { req.setValue(installId, forHTTPHeaderField: "X-Extentos-Install-Id") }
        guard let (data, resp) = try? await session.upload(for: req, from: bytes),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Both required — `url` is what the glasses fetch, `id` is the delete
        // handle we must retain. Missing either = unusable.
        guard let id = json["id"] as? String, let hostedUrl = json["url"] as? String,
              !id.isEmpty, !hostedUrl.isEmpty
        else { return nil }
        return HostedAsset(id: id, url: hostedUrl)
    }

    func delete(id: String, kind: MediaKind) async {
        var comps = URLComponents(string: endpointFor(kind))
        comps?.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        if let installId { req.setValue(installId, forHTTPHeaderField: "X-Extentos-Install-Id") }
        // Best-effort + idempotent: a missing object is success, failures swallowed.
        _ = try? await session.data(for: req)
    }
}

/// Durable backing for the core registry: the core owns the map + keying, this
/// persists its snapshot to one JSON file. ONE store/registry serves BOTH kinds.
/// Tolerant by design — a missing or corrupt file yields an empty registry
/// rather than crashing; the worst case is one asset re-uploads.
final class HostedMediaStore: @unchecked Sendable {
    let registry: HostedMediaRegistry
    private let file: URL?
    private let lock = NSLock()

    init(file: URL?) {
        self.file = file
        let json = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        self.registry = HostedMediaRegistry.restore(json: json)
    }

    func persist() {
        guard let file else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? registry.snapshotJson().write(to: file, atomically: true, encoding: .utf8)
    }

    /// Where the snapshot lives — Application Support, the iOS analogue of
    /// Android's filesDir. nil (in-memory only) if it cannot be resolved: within
    /// -session dedup still holds, only cross-session reuse is skipped.
    static func defaultFile() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return dir.appendingPathComponent("extentos/hosted-media.json")
    }
}
