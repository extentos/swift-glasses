// K4 — the high-quality voice's download surface (doc 19; Asger's product
// requirement, 2026-07-23/24): the SDK NEVER downloads on its own — the
// DEVELOPER calls this from wherever their flow decides (a settings
// screen, a first-engagement prompt), with size known up front, live
// progress, resumability, and deletion. Until the model is present the
// voice serves the phone's system voice (the shipped fallback), and
// upgrades in place on the next session start after the download lands.
//
// Delivery: 358 individually-fetched files from the Hugging Face mirror of
// the exact sherpa-onnx bundle (no archive extraction on iOS). Large files
// verify against HF's own SHA-256; small espeak data files verify by exact
// size. Already-valid files are skipped — a cancelled download RESUMES.

import CryptoKit
import Foundation

public enum KokoroVoiceModel {

    public enum DownloadError: Error {
        case documentsUnavailable
        case httpStatus(Int, path: String)
        case integrityMismatch(path: String)
    }

    /// Total download size, for the developer's "size expectation" UI.
    public static var totalBytes: Int { KokoroModelManifest.totalBytes }

    /// True when every manifest file is present and the right size —
    /// selecting the Kokoro voice will actually serve Kokoro.
    public static func isInstalled() -> Bool {
        guard let root = ExtentosLocalVoice.modelDirectory else { return false }
        let fm = FileManager.default
        for e in KokoroModelManifest.entries {
            let p = root.appendingPathComponent(e.path).path
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  (attrs[.size] as? Int) == e.size else { return false }
        }
        return true
    }

    /// Remove the voice model (the developer's "free up space" affordance).
    public static func delete() throws {
        guard let root = ExtentosLocalVoice.modelDirectory else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Download (or resume) the voice model. `progress` receives overall
    /// fraction [0,1] weighted by BYTES (the b-probe lesson: file-count
    /// progress sticks at 1% while the big model downloads). Cancellation
    /// of the surrounding Task stops between files; completed files are
    /// kept and a later call resumes. Throws on network/integrity failure —
    /// safe to retry.
    public static func download(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let root = ExtentosLocalVoice.modelDirectory else {
            throw DownloadError.documentsUnavailable
        }
        let fm = FileManager.default
        let session = URLSession(configuration: .default)
        var doneBytes = 0
        let total = Double(KokoroModelManifest.totalBytes)

        for e in KokoroModelManifest.entries {
            try Task.checkCancellation()
            let dest = root.appendingPathComponent(e.path)
            if let attrs = try? fm.attributesOfItem(atPath: dest.path),
               (attrs[.size] as? Int) == e.size {
                doneBytes += e.size
                progress(Double(doneBytes) / total)
                continue // resume: already valid
            }
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let url = URL(string: KokoroModelManifest.repoBase + e.path) else { continue }
            let (tmp, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw DownloadError.httpStatus(http.statusCode, path: e.path)
            }
            if let expected = e.sha256 {
                let digest = try Self.sha256(of: tmp)
                guard digest == expected else {
                    try? fm.removeItem(at: tmp)
                    throw DownloadError.integrityMismatch(path: e.path)
                }
            } else if let attrs = try? fm.attributesOfItem(atPath: tmp.path),
                      (attrs[.size] as? Int) != e.size {
                try? fm.removeItem(at: tmp)
                throw DownloadError.integrityMismatch(path: e.path)
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            doneBytes += e.size
            progress(Double(doneBytes) / total)
        }
    }

    /// Streamed SHA-256 (the model file is 330MB — never load it whole).
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
