import Foundation

/// Cross-session persistent memory (v0) — the SDK half of the persistent
/// profile loop: load the stored profile at session start + inject it as
/// context, extract durable signal at session end + merge it back.
///
/// Everything here is **best-effort**: any failure (no credential yet,
/// network, non-2xx, parse) degrades to "no memory this session" — it never
/// throws into the live session, and a failed write leaves the prior profile
/// intact for the next session to retry.
///
/// The profile RENDER, extraction prompt/schema/merge rules, and the
/// per-model parameter rules are CORE-OWNED (realtime/memory.rs, hoisted
/// 2026-07-04) — this type is only the URLSession transport around them.
/// Mirrors the post-hoist Kotlin `PersistentMemoryStore`.
struct PersistentMemoryStore: Sendable {

    /// Extentos `/v1/memory` endpoint, or nil in unavailable modes (→ no-op).
    let memoryUrl: String?
    /// chat/completions endpoint for the extraction model.
    let chatCompletionsUrl: String
    /// Auth (token + attribution headers), shared with the whole session.
    let backing: AssistantBacking
    /// Memory model — `AssistantConfig.compactionModel` falling back to the
    /// core default.
    let model: String
    /// Optional dev-supplied end-user id (`AssistantConfig.memoryUserId`);
    /// sent as `x-extentos-end-user-id` so the profile keys on the app user
    /// rather than the device.
    let userId: String?

    /// True when persistent memory can run against the Extentos store.
    var available: Bool { memoryUrl != nil }

    private func authedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        backing.applyAuth(to: &request, token: token)
        if let userId, !userId.isEmpty {
            request.setValue(userId, forHTTPHeaderField: "x-extentos-end-user-id")
        }
        return request
    }

    /// GET the stored profile for this end-user — the `profile` object as a
    /// JSON string, or nil if none / unavailable / any failure.
    func load() async -> String? {
        guard let memoryUrl, let url = URL(string: memoryUrl),
              let token = backing.authToken() else { return nil }
        let request = authedRequest(url: url, token: token)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = parsed["profile"] as? [String: Any],
              let profileData = try? JSONSerialization.data(withJSONObject: profile)
        else { return nil }
        return String(data: profileData, encoding: .utf8)
    }

    /// PUT the merged profile. Best-effort; false = not persisted this time.
    @discardableResult
    func save(profileJson: String) async -> Bool {
        guard let memoryUrl, let url = URL(string: memoryUrl),
              let token = backing.authToken(),
              let profileData = profileJson.data(using: .utf8),
              let profile = try? JSONSerialization.jsonObject(with: profileData),
              let payload = try? JSONSerialization.data(withJSONObject: ["profile": profile])
        else { return false }
        var request = authedRequest(url: url, token: token)
        request.httpMethod = "PUT"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Extract durable signal from `turns` and merge into `existing`,
    /// returning the updated profile JSON string. nil on any failure (the
    /// caller skips the write); `existing` unchanged when nothing to learn.
    func extractAndMerge(existing: String?, turns: [RealtimeTurn], nowIso: String) async -> String? {
        guard !turns.isEmpty else { return existing }
        guard let token = backing.authToken(),
              let url = URL(string: chatCompletionsUrl) else { return nil }
        // Prompt/schema, transcript format, and params are core-owned.
        let body = memoryExtractRequestBody(
            model: model, existingProfileJson: existing, turns: turns, nowIso: nowIso
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        backing.applyAuth(to: &request, token: token)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        // Extraction + must-be-a-JSON-object validation are core-owned.
        return memoryExtractedProfile(responseBody: text)
    }
}
