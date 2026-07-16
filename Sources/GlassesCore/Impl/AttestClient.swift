import Foundation
import DeviceCheck
import CryptoKit

// Layer 3 SDK attestation client (iOS side).
// Mirror of android-library/.../AttestClient.kt.
// Spec: docs/TELEMETRY_PRODUCT_PLAN.md § Layer 3: Cryptographic attestation.
//
// Two-stage flow (App Attest is heavier than Play Integrity):
//
//   STAGE 1 — INITIAL ATTESTATION (one-time per install):
//     1. DCAppAttestService.shared.generateKey() → opaque keyId (private key
//        sealed in Secure Enclave; we never see it).
//     2. attestKey(keyId, clientDataHash:) → CBOR attestation blob with the
//        cert chain rooted at Apple's App Attest Root CA + the public key.
//     3. POST { attestation, keyId, clientDataHash, appId, anonymousDeviceId }
//        to /api/attest/initial. Backend validates the chain + stores the
//        public key keyed by keyId, returns a 24h session JWT.
//     4. Persist keyId to Keychain so STAGE 1 only happens once per install.
//
//   STAGE 2 — JWT REFRESH (every ~23h):
//     1. Load keyId from Keychain.
//     2. generateAssertion(keyId, clientDataHash:) → lighter CBOR with
//        signature + authenticatorData (no cert chain).
//     3. POST { assertion, keyId, challenge, appId } to /api/attest.
//        Backend loads the stored public key, ECDSA-verifies, mints JWT.
//
// URLSessionTelemetryPoster reads getJWT() before each post and attaches
// Authorization: Bearer when present. First batch may arrive un-attested
// (tiny window before initial attestation completes); the backend tolerates
// that and routes those events to prod-unattested.
//
// In .development we don't attest; dev events don't need a JWT.
//
// Graceful degrade — every failure path stays un-attested rather than
// crashing the host app:
//   - DCAppAttestService.isSupported == false  → simulator / iOS < 14 / unsupported
//   - generateKey / attestKey / generateAssertion throws → device + Apple servers
//     have to cooperate; we backoff and retry like the Android side
//   - Backend rejects the attestation/assertion → stay un-attested

actor AttestClient {
    private let attestEndpoint: URL
    private let appId: String?
    private let anonymousDeviceId: String
    private let effectiveEnvironment: ExtentosEnvironment
    private let session: URLSession
    private let nowMs: @Sendable () -> Int64

    /// (jwt, expiresAtMs). Refreshed in background; nil until first success.
    private var current: (jwt: String, expiresAtMs: Int64)?
    private var attestTask: Task<Void, Never>?

    init(
        attestEndpoint: URL,
        appId: String?,
        anonymousDeviceId: String,
        effectiveEnvironment: ExtentosEnvironment,
        session: URLSession = .shared,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.attestEndpoint = attestEndpoint
        self.appId = appId
        self.anonymousDeviceId = anonymousDeviceId
        self.effectiveEnvironment = effectiveEnvironment
        self.session = session
        self.nowMs = nowMs
    }

    /// Returns the cached JWT iff still valid and not near expiry.
    func getJWT() -> String? {
        guard let snap = current else { return nil }
        return nowMs() < snap.expiresAtMs ? snap.jwt : nil
    }

    /// Kick off attestation in background. Idempotent.
    func start() {
        // Dev environment never attests; backend dev endpoint doesn't require it.
        if effectiveEnvironment == .development { return }
        guard let id = appId, !id.isEmpty else { return }
        // Simulator + iOS < 14 + de-DRMed devices — App Attest not available.
        // The SDK stays in un-attested mode; telemetry posts without a JWT.
        guard DCAppAttestService.shared.isSupported else { return }
        if attestTask != nil { return }
        attestTask = Task.detached(priority: .background) { [weak self] in
            await self?.attemptAttest()
        }
    }

    private func attemptAttest() async {
        var attempt = 0
        while !Task.isCancelled {
            let ok = await doAttest()
            if ok { return }
            attempt += 1
            // Same backoff shape as Android: 30s, 2m, 10m, 1h.
            let delayNs: UInt64 = switch attempt {
            case 1: 30_000_000_000
            case 2: 120_000_000_000
            case 3: 600_000_000_000
            default: 3_600_000_000_000
            }
            try? await Task.sleep(nanoseconds: delayNs)
        }
    }

    private func doAttest() async -> Bool {
        guard let id = appId else { return false }

        // Decide between STAGE 1 (initial attest) and STAGE 2 (assertion) by
        // looking up an existing keyId in Keychain.
        if let storedKeyId = AppAttestKeyStore.loadKeyId(appId: id, anonymousDeviceId: anonymousDeviceId) {
            // STAGE 2 — fast path; subsequent JWT refreshes land here.
            return await doAssertion(keyId: storedKeyId, appId: id)
        }

        // STAGE 1 — first run, or Keychain was wiped (user reinstalled app, etc).
        return await doInitialAttest(appId: id)
    }

    private func doInitialAttest(appId: String) async -> Bool {
        let service = DCAppAttestService.shared
        let keyId: String
        do {
            keyId = try await service.generateKey()
        } catch {
            return false
        }
        // clientDataHash is SHA-256 of anything the SDK chooses. We bind it to
        // the anonymousDeviceId + timestamp + a random nonce so a stolen
        // attestation can't be replayed to a different device-day. The hash
        // itself is not secret (it's sent over the wire), but the binding is
        // useful for forensic correlation.
        let clientData = clientDataPayload()
        let clientDataHash = Data(SHA256.hash(data: clientData))
        let attestation: Data
        do {
            attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
        } catch {
            return false
        }

        // The /attest/initial endpoint is co-located with /attest on the same
        // host — just append "/initial".
        let initialURL = attestEndpoint.appendingPathComponent("initial")
        let body: [String: Any] = [
            "platform": "ios",
            "attestation": attestation.base64EncodedString(),
            // DCAppAttestService returns the keyId already base64-encoded
            // (per Apple's docs). Send as-is so the backend's
            // Buffer.from(keyId, "base64") round-trips.
            "keyId": keyId,
            "clientDataHash": clientDataHash.base64EncodedString(),
            "appId": appId,
            "anonymousDeviceId": anonymousDeviceId,
        ]
        guard let resp = await postAttestJSON(url: initialURL, body: body) else { return false }
        guard resp.jwt != nil else { return false }
        // Persist the keyId so we never re-do STAGE 1 on this install.
        AppAttestKeyStore.saveKeyId(keyId, appId: appId, anonymousDeviceId: anonymousDeviceId)
        cacheJWT(resp)
        return true
    }

    private func doAssertion(keyId: String, appId: String) async -> Bool {
        let service = DCAppAttestService.shared
        let challengeData = randomBytes(32)
        let clientDataHash = Data(SHA256.hash(data: challengeData))
        let assertion: Data
        do {
            assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
        } catch {
            // generateAssertion fails if the key was invalidated by iOS
            // (e.g. backup restore — keyId no longer matches a Secure Enclave
            // key). Clear Keychain and fall back to a fresh STAGE 1 next run.
            AppAttestKeyStore.deleteKeyId(appId: appId, anonymousDeviceId: anonymousDeviceId)
            return false
        }
        let body: [String: Any] = [
            "platform": "ios",
            "assertion": assertion.base64EncodedString(),
            "keyId": keyId,
            "challenge": clientDataHash.base64EncodedString(),
            "appId": appId,
            "anonymousDeviceId": anonymousDeviceId,
        ]
        guard let resp = await postAttestJSON(url: attestEndpoint, body: body) else { return false }
        guard resp.jwt != nil else { return false }
        cacheJWT(resp)
        return true
    }

    private struct AttestResponse {
        let jwt: String?
        let expiresInSeconds: Int
    }

    private func postAttestJSON(url: URL, body: [String: Any]) async -> AttestResponse? {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData
        request.timeoutInterval = 10
        do {
            let (data, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jwt = obj["token"] as? String, !jwt.isEmpty,
                  let expiresInSeconds = obj["expiresInSeconds"] as? Int else {
                return nil
            }
            return AttestResponse(jwt: jwt, expiresInSeconds: expiresInSeconds)
        } catch {
            return nil
        }
    }

    private func cacheJWT(_ resp: AttestResponse) {
        guard let jwt = resp.jwt else { return }
        let expiresAtMs = nowMs() + Int64(resp.expiresInSeconds) * 1000 - Self.jwtRefreshLeadMs
        current = (jwt, expiresAtMs)
    }

    private func clientDataPayload() -> Data {
        // Loosely-structured client data — purely for nonce uniqueness.
        // The backend doesn't parse this; it only verifies the SHA-256 hash
        // of these bytes matches what the credCert's nonce extension contains.
        let dict: [String: Any] = [
            "ts": nowMs(),
            "device": anonymousDeviceId,
            "nonce": randomBytes(16).base64EncodedString(),
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data(randomBytes(32))
    }

    private func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return data
    }

    // Refresh JWT 30 minutes before expiry so flushes near boundary
    // don't get an expired token.
    private static let jwtRefreshLeadMs: Int64 = 30 * 60 * 1000
}

/// Persists the App Attest keyId in the iOS Keychain so STAGE 1 (full
/// attestation) only runs once per install. The keyId itself is not
/// sensitive — it's a public identifier — but Keychain is the standard
/// per-app secure storage location and it survives ordinary uninstall/
/// reinstall via iCloud Keychain on supported configurations.
enum AppAttestKeyStore {
    private static let serviceName = "com.extentos.glasses.appattest"

    static func saveKeyId(_ keyId: String, appId: String, anonymousDeviceId: String) {
        let account = "\(appId)|\(anonymousDeviceId)"
        let data = Data(keyId.utf8)
        // Best-effort: delete any prior key for this account, then add fresh.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadKeyId(appId: String, anonymousDeviceId: String) -> String? {
        let account = "\(appId)|\(anonymousDeviceId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteKeyId(appId: String, anonymousDeviceId: String) {
        let account = "\(appId)|\(anonymousDeviceId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

func defaultAttestEndpoint(_ env: ExtentosEnvironment) -> URL {
    switch env {
    case .production:
        return URL(string: "https://prod.api.extentos.com/api/attest")!
    case .beta, .development:
        return URL(string: "https://api.extentos.com/api/attest")!
    }
}
