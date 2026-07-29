import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

// Glasses audio that arrives as BYTES, presented as an audio input.
//
// `SharedAudioInput` fans out buffers from `AVAudioEngine.inputNode` — the
// phone's microphone. That is the right source for every device that pairs as a
// Bluetooth headset, because such a device simply BECOMES the phone's
// microphone and the OS routes it for us.
//
// Brilliant does not do that. Halo streams its microphone over its own BLE link
// and never becomes a system audio device at all, so there is no input node to
// tap: the audio lands in our process as PCM16 on a GATT notification. Anything
// built on "listen to the phone's mic" is deaf to it.
//
// This is the adapter that closes the gap. It implements the SAME
// `AudioInputSubscribing` seam the microphone-backed input does, so
// `PlatformSttEngine` drives Brilliant with no knowledge that anything is
// different — and the engine's hard-won behaviour (authorization, continuous
// restart after each final, the silence endpointer that SFSpeechRecognizer does
// not provide in buffer mode) is reused rather than reimplemented for a second
// audio source. Writing a separate recogniser here would have been a second
// place for recognition to drift.

#if canImport(AVFAudio)

final class BleAudioInput: AudioInputSubscribing, @unchecked Sendable {

    private let lock = NSLock()
    private var consumers: [UUID: BufferHandler] = [:]
    private var format: AVAudioFormat?

    /// Called when the first consumer subscribes and the last unsubscribes, so
    /// the glasses' microphone runs only while something is listening. An app
    /// that never asks never pays for the radio.
    private let onFirstSubscribe: () -> Void
    private let onLastUnsubscribe: () -> Void

    init(
        onFirstSubscribe: @escaping () -> Void = {},
        onLastUnsubscribe: @escaping () -> Void = {}
    ) {
        self.onFirstSubscribe = onFirstSubscribe
        self.onLastUnsubscribe = onLastUnsubscribe
    }

    // ── AudioInputSubscribing ────────────────────────────────────────────────

    func subscribe(_ handler: @escaping BufferHandler) -> UUID? {
        let id = UUID()
        lock.lock()
        let wasEmpty = consumers.isEmpty
        consumers[id] = handler
        lock.unlock()
        if wasEmpty { onFirstSubscribe() }
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock()
        consumers.removeValue(forKey: id)
        let nowEmpty = consumers.isEmpty
        lock.unlock()
        if nowEmpty { onLastUnsubscribe() }
    }

    /// The format of the audio the glasses are sending, once a chunk has
    /// arrived to establish it. Nil before then — consumers that must declare a
    /// track format up front subscribe first, exactly as with the mic-backed
    /// input.
    func currentFormat() -> AVAudioFormat? {
        lock.lock(); defer { lock.unlock() }
        return format
    }

    // ── Feed ─────────────────────────────────────────────────────────────────

    /// Hand over one chunk of PCM16 little-endian mono, as it comes off the
    /// link.
    ///
    /// Converted to the float format `SFSpeechAudioBufferRecognitionRequest`
    /// and every other consumer expects. Called from the BLE callback, so it
    /// does no work beyond the conversion — anything slower would hold up taps,
    /// display acknowledgements and every other message on the link.
    func feed(pcm16: Data, sampleRate: Int) {
        guard !pcm16.isEmpty else { return }
        guard let buffer = Self.makeBuffer(pcm16: pcm16, sampleRate: sampleRate) else { return }

        lock.lock()
        format = buffer.format
        let handlers = Array(consumers.values)
        lock.unlock()

        // A timestamp is required by the seam; sample time is the honest one to
        // give, since these buffers have no host-clock origin.
        let when = AVAudioTime(sampleTime: 0, atRate: Double(sampleRate))
        for handler in handlers {
            handler(buffer, when)
        }
    }

    /// PCM16-LE bytes to a float PCM buffer.
    ///
    /// Non-interleaved float32 because that is what `AVAudioEngine` taps
    /// produce, so downstream consumers see the same shape whether the audio
    /// came from the phone's microphone or off a BLE characteristic.
    static func makeBuffer(pcm16: Data, sampleRate: Int) -> AVAudioPCMBuffer? {
        let sampleCount = pcm16.count / 2
        guard sampleCount > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(sampleRate),
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        pcm16.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<sampleCount {
                let lo = UInt16(bytes[i * 2])
                let hi = UInt16(bytes[i * 2 + 1])
                let sample = Int16(bitPattern: lo | (hi << 8))
                channel[i] = Float(sample) / 32768.0
            }
        }
        return buffer
    }
}

#endif
