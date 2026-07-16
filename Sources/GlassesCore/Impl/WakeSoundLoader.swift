import AVFoundation
import Foundation

/// Downloads the dashboard's custom wake-chime URL and decodes it to
/// PCM16-LE MONO at the requested rate for `RealtimeVoiceCore.setWakeSound`
/// (the core owns storage + playback; this is pure codec plumbing).
///
/// Best-effort by design: any failure returns nil and the caller keeps the
/// core's built-in synth chime — a wake must never break on a bad asset.
/// Mirrors the Kotlin `WakeSoundLoader` (one decoder; Android's second
/// legacy decoder was deliberately not ported).
enum WakeSoundLoader {

    /// ~10s cap on the decoded chime so a mis-uploaded song can't balloon
    /// memory; matches the dashboard's upload guidance.
    private static let maxSamples = 10 * 48_000

    static func load(url: String, targetRate: Int32) async -> Data? {
        guard let remote = URL(string: url) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: remote),
              (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
              !data.isEmpty
        else { return nil }

        // AVAudioFile reads from a file URL — stage the download.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("extentos-wake-\(UUID().uuidString)")
            .appendingPathExtension(remote.pathExtension.isEmpty ? "mp3" : remote.pathExtension)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp)
            return try decode(fileUrl: tmp, targetRate: targetRate)
        } catch {
            return nil
        }
    }

    private static func decode(fileUrl: URL, targetRate: Int32) throws -> Data? {
        let file = try AVAudioFile(forReading: fileUrl)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(targetRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            return nil
        }

        var out = Data()
        var fileDone = false
        while out.count / 2 < maxSamples {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { packetCount, inputStatus in
                if fileDone {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let inBuf = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: packetCount
                ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuf)
                } catch {
                    fileDone = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    fileDone = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuf
            }
            if convError != nil { return nil }
            if outBuf.frameLength > 0, let ch = outBuf.int16ChannelData {
                out.append(
                    Data(bytes: ch[0], count: Int(outBuf.frameLength) * MemoryLayout<Int16>.size)
                )
            }
            if status == .endOfStream || (status == .inputRanDry && fileDone) { break }
            if outBuf.frameLength == 0 && fileDone { break }
        }
        return out.isEmpty ? nil : out
    }
}
