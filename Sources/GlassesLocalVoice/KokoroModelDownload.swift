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
            // `doneBytes` is what COMPLETED entries contributed; the streaming
            // download adds this entry's bytes as they arrive, so the fraction
            // moves DURING the file rather than only after it.
            let completedBefore = doneBytes
            let (tmp, response) = try await StreamingDownload.run(
                url: url,
                session: session,
                onBytes: { written in
                    progress(min(1.0, Double(completedBefore + Int(written)) / total))
                }
            )
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

    /// A download that reports bytes while they arrive.
    ///
    /// `URLSession.download(from:)` returns only when the file is complete, so
    /// a caller learns nothing during it. That is tolerable for a manifest of
    /// similar files and useless for this one: `model.onnx` is 93.5% of the
    /// total, so progress showed ~5% and then fifteen minutes of silence before
    /// jumping to 100%. The comment on `download(progress:)` already named the
    /// failure — "file-count progress sticks at 1% while the big model
    /// downloads" — but the byte-weighting was applied BETWEEN entries and not
    /// WITHIN the entry that is the whole download.
    ///
    /// The delegate hands back a temp URL the CALLER owns. `didFinishDownloading`
    /// deletes its location the moment the method returns, so the file is moved
    /// out synchronously inside it — the one rule of this API that bites.
    private final class StreamingDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onBytes: @Sendable (Int64) -> Void
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var finished = false
        private let lock = NSLock()
        /// A 64 KB socket buffer over 345 MB is ~5,500 callbacks; a progress
        /// bar needs far fewer, and each one hops to the main actor.
        private static let reportEveryBytes: Int64 = 256 * 1024
        private var lastReported: Int64 = 0

        private init(onBytes: @escaping @Sendable (Int64) -> Void) {
            self.onBytes = onBytes
        }

        static func run(
            url: URL,
            session: URLSession,
            onBytes: @escaping @Sendable (Int64) -> Void
        ) async throws -> (URL, URLResponse) {
            let delegate = StreamingDownload(onBytes: onBytes)
            // A delegate session of its own: the caller's shared session has no
            // delegate, and attaching one after the fact is not possible.
            let config = session.configuration
            let delegated = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { delegated.finishTasksAndInvalidate() }
            let task = delegated.downloadTask(with: url)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    delegate.continuation = cont
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        private func settle(_ result: Result<(URL, URLResponse), Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(with: result)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            lock.lock()
            let due = totalBytesWritten - lastReported >= Self.reportEveryBytes
            if due { lastReported = totalBytesWritten }
            lock.unlock()
            if due { onBytes(totalBytesWritten) }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // MUST move synchronously — `location` is gone after this returns.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("extentos-kokoro-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: dest)
            } catch {
                settle(.failure(error))
                return
            }
            let response = downloadTask.response ?? URLResponse()
            settle(.success((dest, response)))
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            if let error { settle(.failure(error)) }
            // No error means didFinishDownloadingTo already settled it.
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
