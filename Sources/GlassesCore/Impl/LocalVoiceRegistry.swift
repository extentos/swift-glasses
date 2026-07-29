// Local tier voice seam (voice rung 2 — doc 19). GlassesCore stays free of
// the sherpa-onnx/Kokoro dependency the same way it stays MLX-free: the
// engine lives in the GlassesLocalVoice product and registers here with one
// bootstrap line. The provider's mouth consults the registry when the
// managed config selects a non-system local voice; an unregistered or
// not-ready synthesizer falls back to the system voice — serve-until-ready,
// the same contract the dashboard documents.

import Foundation

/// The local tier's synthesizer contract. Implementations must be
/// abort-safe: `cancel()` stops an in-flight synthesis promptly (barge-in)
/// and a cancelled synthesis must never emit further chunks.
public protocol LocalVoiceSynthesizer: Sendable {
    /// True once the engine + model are loaded. Not-ready = the caller
    /// serves the system voice for that segment.
    func isReady() async -> Bool
    /// Load the model (no-op when already loaded; missing model files keep
    /// the synthesizer not-ready — never throws, never blocks the wake).
    func warmUp() async
    /// Synthesize `text`, delivering PCM16 mono chunks via `emit` AS THEY
    /// ARE PRODUCED (streaming playback — the K2 spike showed short replies
    /// cost ~0.8s synthesis; playback must start at the first chunk, not
    /// the last). Returns the total audio duration in seconds, or nil on
    /// failure/cancellation (the caller falls back / stops accounting).
    func synthesize(
        _ text: String,
        emit: @escaping @Sendable (_ pcm16: Data, _ sampleRate: Int32) -> Void
    ) async -> Double?
    /// Abort the in-flight synthesis, if any.
    func cancel() async
}

/// GlassesLocalVoice registers its factory here (one
/// `ExtentosLocalVoice.register()` call in the app bootstrap).
public enum LocalVoiceRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var instances: [String: any LocalVoiceSynthesizer] = [:]

    nonisolated(unsafe) public static var synthesizerFactory:
        (@Sendable (_ voiceId: String) -> (any LocalVoiceSynthesizer)?)? {
        didSet {
            // Instances minted by a replaced factory are stale — drop them
            // so the next resolve() serves the new factory's engines.
            lock.lock()
            instances.removeAll()
            lock.unlock()
        }
    }

    /// Resolve-and-memoize: ONE synthesizer instance per voice id process-
    /// wide, so the assistant's mouth and a direct `audio.speak()` share a
    /// loaded engine instead of holding two copies of the model in RAM.
    /// The engine's own synthesis serialization handles the two callers.
    /// Returns nil when no factory is registered or it doesn't claim the id.
    public static func resolve(_ voiceId: String) -> (any LocalVoiceSynthesizer)? {
        guard let factory = synthesizerFactory else { return nil }
        lock.lock()
        if let existing = instances[voiceId] {
            lock.unlock()
            return existing
        }
        lock.unlock()
        guard let made = factory(voiceId) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let raced = instances[voiceId] { return raced }
        instances[voiceId] = made
        return made
    }
}
