import Foundation

// Phase 4 — `tool(...)` builder extensions on `AssistantConfigBuilder`.
// Sugar over the `ToolDefinition` struct primitive (synthesis #7 raw
// form). Customer can always skip these and instantiate `ToolDefinition`
// directly for programmatic registration — that's the
// customer-can-skip-it lock-test.
//
// Two overloads in v1:
//
//   1. tool(_ name:, description:, blocking:, body: () async throws -> ToolResult)
//      No-arg case. Schema is null (provider sends the empty
//      `{type:"object", properties:{}, required:[]}`). Most tools fit
//      here — "take_picture", "stop_video", "get_route_remaining".
//
//   2. tool<Args: Codable>(_ name:, description:, schema:, blocking:,
//                          body: (Args) async throws -> ToolResult)
//      Typed-args case with EXPLICIT schema per Q3 lock. Body receives a
//      deserialized `Args` instance (round-tripped through
//      JSONValue.convertToCodable).
//
// Both accept `blocking: Bool = false` (synthesis #9 default non-blocking
// with per-tool opt-out).
//
// ## Q3 — Why explicit schema?
//
// Kotlin's `inline fun <reified Args> tool(...)` infers the JSON Schema
// at registration time via `kotlinx.serialization.serializer<Args>().descriptor`
// — free runtime type introspection. Swift has no equivalent without
// Swift 5.9+ macros. v1 ships explicit schema; the `@AssistantTool` macro
// for auto-inference lands in v1.1+. The JSON Schema sent to OpenAI is
// identical regardless of which platform produced it.
//
// Documented as an intentional asymmetry per
// `phase-4-mac-vps-orientation.md` iOS-question #3.
//
// NOT A DSL in the pre-pivot Extentos sense — this is a plain Swift
// builder extension with no library-side runtime interpretation. The
// customer could replace every `tool(...) { ... }` line with
// `builder.tools.append(ToolDefinition(...))` and the result is identical.

public extension AssistantConfigBuilder {

    /// No-arg tool. The body receives no arguments — the registered tool
    /// schema is `{type:"object", properties:{}, required:[]}` (OpenAI's
    /// shape for parameterless function tools). Most camera/notes/status
    /// tools fit here.
    ///
    /// - Parameter name: Stable identifier the model emits in
    ///   `function_call` events. snake_case convention.
    /// - Parameter description: Natural-language description of when to
    ///   call. The model + the Mock provider read this. See
    ///   `ToolDefinition.description` for guidance.
    /// - Parameter blocking: Per-tool opt-out from non-blocking default
    ///   (synthesis #9). Default false (model speaks "let me check..."
    ///   while tool runs).
    /// - Parameter body: Tool implementation. `async throws`; runs in a
    ///   tracked Task per Q4. Throws emit `AssistantEvent.error` rather
    ///   than tearing the session down.
    func tool(
        _ name: String,
        description: String,
        blocking: Bool = false,
        body: @escaping @Sendable () async throws -> ToolResult
    ) {
        tools.append(ToolDefinition(
            name: name,
            description: description,
            schema: nil,
            blocking: blocking,
            body: { _ in
                do { return try await body() }
                catch let shortCircuit as ToolResultShortCircuit { return shortCircuit.result }
            }
        ))
    }

    /// Typed-args tool with EXPLICIT JSON Schema (Q3 lock — no Mirror
    /// walk in v1). `Args` must be `Codable`. The body receives a
    /// deserialized `Args` instance — the runtime rounds the incoming
    /// `JSONValue` through `JSONDecoder` to produce it.
    ///
    /// Example:
    /// ```swift
    /// struct SetReminderArgs: Codable {
    ///     let text: String
    ///     let minutesFromNow: Int
    /// }
    ///
    /// $0.tool(
    ///     "set_reminder",
    ///     description: "Set a reminder for the user.",
    ///     schema: .object([
    ///         "type": .string("object"),
    ///         "properties": .object([
    ///             "text": .object(["type": .string("string")]),
    ///             "minutesFromNow": .object(["type": .string("integer")])
    ///         ]),
    ///         "required": .array([.string("text"), .string("minutesFromNow")])
    ///     ])
    /// ) { (args: SetReminderArgs) in
    ///     reminders.add(args.text, delayMinutes: args.minutesFromNow)
    ///     return .ok("reminder set")
    /// }
    /// ```
    ///
    /// If `Args` decoding fails (the model emitted args that don't match
    /// the schema), the wrapping body throws and the session emits
    /// `AssistantEvent.error` with the decode failure as cause.
    ///
    /// For raw `JSONValue` args (skip Codable round-trip), use this
    /// overload with `Args = JSONValue` — JSONValue is itself Codable
    /// and round-trips losslessly.
    func tool<Args: Codable & Sendable>(
        _ name: String,
        description: String,
        schema: JSONValue,
        blocking: Bool = false,
        body: @escaping @Sendable (Args) async throws -> ToolResult
    ) {
        tools.append(ToolDefinition(
            name: name,
            description: description,
            schema: schema,
            blocking: blocking,
            body: { argsJson in
                let args: Args
                do {
                    args = try argsJson.decode(as: Args.self)
                } catch {
                    // Finding #9: a required-field omission (the model
                    // sometimes calls a tool with `{}` on its first attempt)
                    // must not surface a raw Swift DecodingError as the tool
                    // output — the model reads that. Return a clean,
                    // actionable message so it can self-correct.
                    return .err("invalid arguments for '\(name)': \(toolArgDecodeMessage(error))")
                }
                do { return try await body(args) }
                catch let shortCircuit as ToolResultShortCircuit { return shortCircuit.result }
            }
        ))
    }
}

/// Sentinel thrown by `orToolError()` to short-circuit a tool body with a specific
/// `ToolResult`. Caught inside the `tool(...)` wrappers so the message reaches the
/// MODEL as a `ToolResult.err` (which it relays), not an `AssistantEvent.error`.
struct ToolResultShortCircuit: Error {
    let result: ToolResult
}

public extension ExtentosResult where Failure == CaptureError {
    /// Unwrap a capture inside a `tool { }` body: returns the value on success, or
    /// short-circuits the tool with a `ToolResult.err` carrying the failure's
    /// canonical, user-actionable message (e.g. `.streamPaused` → "The camera is
    /// paused. Tap the right temple of your glasses to resume …"). So an AI agent you
    /// wire to the camera always receives a reason it can relay to the user — not a
    /// generic "camera failed". The message is the shared core's single source of
    /// truth (`captureErrorMessage`). Mirrors Kotlin `orToolError { }`.
    ///
    /// ```swift
    /// $0.tool("take_photo", description: "…") {
    ///     let photo = try glasses.camera.capturePhoto().orToolError()
    ///     return .ok("took a photo")
    /// }
    /// ```
    ///
    /// Skippable per the convenience-API lock-test: switch on the `ExtentosResult`
    /// yourself and build any `ToolResult` you like for custom copy.
    func orToolError() throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw ToolResultShortCircuit(result: .err(captureErrorMessage(error: error)))
        }
    }
}

/// Human-readable reason for a tool-argument decode failure — kept free of
/// Swift internals so it reads well to the model that receives it as the
/// tool result.
func toolArgDecodeMessage(_ error: Error) -> String {
    guard let decoding = error as? DecodingError else { return "\(error)" }
    switch decoding {
    case .keyNotFound(let key, _):
        return "missing required field '\(key.stringValue)'"
    case .valueNotFound(_, let context):
        return "missing value for field '\(context.codingPath.last?.stringValue ?? "?")'"
    case .typeMismatch(_, let context):
        return "wrong type for field '\(context.codingPath.last?.stringValue ?? "?")'"
    case .dataCorrupted(let context):
        return "malformed arguments: \(context.debugDescription)"
    @unknown default:
        return "could not parse arguments"
    }
}
