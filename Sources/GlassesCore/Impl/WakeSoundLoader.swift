import AVFoundation
import Foundation

/// Downloads a dashboard sound-slot clip and decodes it to PCM16-LE MONO at
/// the requested rate for the `SoundRegistry` (nothing downstream decodes,
/// so it happens here). Name is historical: the clip library's table and
/// bucket are still `wake_sounds` / `wake-sounds`.
///
/// Best-effort by design: any failure returns nil and that one sound is
/// simply not registered. Mirrors the Kotlin `WakeSoundLoader`.
enum WakeSoundLoader {

    /// ~10s cap on the decoded chime so a mis-uploaded song can't balloon
    /// memory; matches the dashboard's upload guidance.
    private static let maxSamples = 10 * 48_000

    /// Gateway passthrough for the storage CDN — some client networks
    /// (QUIC-hostile paths; the iOS-Simulator-on-VPS case, 2026-07-25:
    /// NSURLErrorCannotParseResponse on every fetch) can't reach the CDN
    /// directly while the gateway host works. The backend locks this route
    /// to the public wake-sounds path.
    private static func proxied(_ url: String) -> URL? {
        var comps = URLComponents(string: "https://api.extentos.com/api/sounds/proxy")
        comps?.queryItems = [URLQueryItem(name: "src", value: url)]
        return comps?.url
    }

    static func load(url: String, targetRate: Int32) async -> Data? {
        guard let remote = URL(string: url) else {
            WakeLedger.shared.note("sound load: bad url")
            return nil
        }
        func fetch(_ from: URL) async throws -> Data {
            let (d, response) = try await URLSession.shared.data(from: from)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard status == 200, !d.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return d
        }
        var data: Data
        do {
            data = try await fetch(remote)
        } catch {
            // Direct CDN fetch failed — fall back to the gateway passthrough.
            guard let via = proxied(url) else {
                WakeLedger.shared.note("sound load: download failed — \(error.localizedDescription)")
                return nil
            }
            do {
                data = try await fetch(via)
                WakeLedger.shared.note("sound load: direct failed, gateway proxy OK")
            } catch {
                WakeLedger.shared.note("sound load: download failed (direct+proxy) — \(error.localizedDescription)")
                return nil
            }
        }

        // AVAudioFile reads from a file URL — stage the download.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("extentos-wake-\(UUID().uuidString)")
            .appendingPathExtension(remote.pathExtension.isEmpty ? "mp3" : remote.pathExtension)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp)
            return try decode(fileUrl: tmp, targetRate: targetRate)
        } catch {
            WakeLedger.shared.note("sound load: decode failed — \(error.localizedDescription)")
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
