import Foundation

// One buffered conversation turn — the SDK's local history vocabulary,
// consumed by `AssistantSession.conversationHistory(limit:)`, replayed to
// the provider on reconnect, and handed to `HistoryCompaction.custom`
// compactors. Mirrors `android-library/.../assistant/Turn.kt` (a sealed
// class there; an enum with associated values here).
//
// Example — feeding history to your own summarizer:
//
//     let context = session.conversationHistory(limit: 50).map { turn in
//         switch turn {
//         case .userText(let text, _): "user: \(text)"
//         case .assistantText(let text, _): "assistant: \(text)"
//         case .toolInvocation(let name, _, let argsJson, _): "tool_call: \(name)(\(argsJson))"
//         case .toolReturn(_, let output, _): "tool_result: \(output)"
//         }
//     }.joined(separator: "\n")

public enum Turn: Sendable, Equatable {

    /// User finished an utterance (provider STT result).
    case userText(text: String, timestampMs: Int64)

    /// Model finished an utterance (output transcript).
    case assistantText(text: String, timestampMs: Int64)

    /// Model called a tool. `argsJson` is the raw arguments JSON string.
    case toolInvocation(name: String, callId: String, argsJson: String, timestampMs: Int64)

    /// A tool body returned. `output` is the string handed back to the model.
    case toolReturn(callId: String, output: String, timestampMs: Int64)

    /// Wall-clock time the turn was buffered, ms since epoch. Captured at
    /// the SDK boundary — use for relative ordering, not provider-exact
    /// timestamps.
    public var timestampMs: Int64 {
        switch self {
        case .userText(_, let t), .assistantText(_, let t):
            return t
        case .toolInvocation(_, _, _, let t), .toolReturn(_, _, let t):
            return t
        }
    }
}
