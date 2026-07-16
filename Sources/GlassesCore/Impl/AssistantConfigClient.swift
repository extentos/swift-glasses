import Foundation

/// The dashboard's live assistant config for this project (Agent tab) —
/// fields the developer may leave code-unset and manage in the dashboard
/// instead. All optional; absent = not configured there.
struct LiveAssistantConfig: Sendable {
    let realtimeModel: String?
    let voice: String?
    let compactionModel: String?
    let withinSessionMemory: String?
    let wakeSoundUrl: String?
    /// The dashboard's "None" wake-sound option — skip the chime entirely
    /// (code-set wakeSoundEnabled=false still wins the other way).
    let wakeSoundDisabled: Bool
    /// The project's uploaded sound library (name = dashboard title). The
    /// session downloads + decodes these and registers them in the shared
    /// SoundRegistry so app code can `playSound(name)`.
    let sounds: [LiveSound]
}

struct LiveSound: Sendable {
    let name: String
    let url: String
}

/// Fetches the project's live assistant config from the backend at session
/// start. Exception-safe by contract: every failure (no app id, network,
/// non-2xx, parse) returns nil and the session falls back to code-set
/// values + hard defaults — start() never blocks on the dashboard.
/// Mirrors Kotlin `AssistantConfigClient` (4s call timeout).
struct AssistantConfigClient: Sendable {
    let endpoint: String
    let appId: String?
    let getJWT: @Sendable () async -> String?

    static func defaultEndpoint(environment: ExtentosEnvironment) -> String {
        "https://\(endpointHost(channel: .operational, env: environment))/api/assistant-config"
    }

    func fetch() async -> LiveAssistantConfig? {
        guard let appId, !appId.isEmpty, let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue(appId, forHTTPHeaderField: "x-extentos-app-id")
        if let jwt = await getJWT() {
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cfg = root["config"] as? [String: Any]
        else { return nil }
        let sounds: [LiveSound] = (cfg["sounds"] as? [[String: Any]])?.compactMap { entry in
            guard let name = entry["name"] as? String, !name.isEmpty,
                  let url = entry["url"] as? String, !url.isEmpty
            else { return nil }
            return LiveSound(name: name, url: url)
        } ?? []
        return LiveAssistantConfig(
            realtimeModel: cfg["realtimeModel"] as? String,
            voice: cfg["voice"] as? String,
            compactionModel: cfg["compactionModel"] as? String,
            withinSessionMemory: cfg["withinSessionMemory"] as? String,
            wakeSoundUrl: cfg["wakeSoundUrl"] as? String,
            wakeSoundDisabled: cfg["wakeSoundDisabled"] as? Bool ?? false,
            sounds: sounds
        )
    }
}

extension AssistantConfig {
    /// Copy with the overlay-resolved memory knobs (every other field kept).
    /// Session-internal — the overlay fills only developer-null fields.
    func overlaying(compactionModel: String?, withinSessionMemory: String?) -> AssistantConfig {
        AssistantConfig(
            provider: provider,
            instructions: instructions,
            tools: tools,
            startActive: startActive,
            onWake: onWake,
            onSleep: onSleep,
            silenceTimeout: silenceTimeout,
            sleepPhrases: sleepPhrases,
            endOnIntent: endOnIntent,
            historyCap: historyCap,
            historyCompaction: historyCompaction,
            compactionModel: compactionModel,
            withinSessionMemory: withinSessionMemory,
            persistentMemory: persistentMemory,
            memoryUserId: memoryUserId,
            memoryStore: memoryStore,
            greeting: greeting,
            wakeSoundEnabled: wakeSoundEnabled,
            includeDeviceInfoTool: includeDeviceInfoTool,
            deviceInfoNote: deviceInfoNote
        )
    }

    /// Append the (optional) core-owned end_conversation tool — parity with
    /// Android's shell-side injection (DefaultAssistantClient.createRuntime).
    /// The tool's name + description are core-owned (realtime/state.rs); only
    /// the body's sleep() binding is platform, so this stays shell-side.
    /// nil = unchanged (endOnIntent false → no end tool appended).
    func appendingTool(_ tool: ToolDefinition?) -> AssistantConfig {
        guard let tool else { return self }
        return AssistantConfig(
            provider: provider,
            instructions: instructions,
            tools: tools + [tool],
            startActive: startActive,
            onWake: onWake,
            onSleep: onSleep,
            silenceTimeout: silenceTimeout,
            sleepPhrases: sleepPhrases,
            endOnIntent: endOnIntent,
            historyCap: historyCap,
            historyCompaction: historyCompaction,
            compactionModel: compactionModel,
            withinSessionMemory: withinSessionMemory,
            persistentMemory: persistentMemory,
            memoryUserId: memoryUserId,
            memoryStore: memoryStore,
            greeting: greeting,
            wakeSoundEnabled: wakeSoundEnabled,
            includeDeviceInfoTool: includeDeviceInfoTool,
            deviceInfoNote: deviceInfoNote
        )
    }
}
