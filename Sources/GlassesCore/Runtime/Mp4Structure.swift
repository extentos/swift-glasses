// Can a player actually open the movie we just wrote?
//
// The Android half of this shipped first (RDQ #88), after a clip recorded on
// real glasses reported success and then would not play: `mdat` understated its
// own length by 12,650 bytes, so the box chain never reached `moov`. iOS was
// MORE exposed than Android, not less — `VideoCaptureSession` returned
// `uri: outputURL.absoluteString` unconditionally, without even reading
// `writer.status` after `finishWriting`, so an outright writer failure produced
// a "successful" clip pointing at an unusable file.
//
// Every decision about what the bytes mean lives in the Rust core
// (`core/extentos-core/src/mp4.rs`), shared with Android. This file owns only
// the genuinely platform-bound part: holding the file handle and seeking.
//
// Works for `.mov` as well as `.mp4` — QuickTime uses the same atom structure,
// and the walk succeeds the moment it reaches `moov`, so a movie whose `ftyp`
// differs (or is absent, as in older QuickTime) is still accepted.

import Foundation

enum Mp4Structure {

    struct Verdict {
        let ok: Bool
        let reason: String
    }

    /// Enough for any real container; a pathological file must not spin.
    private static let maxSteps = 4096

    static func check(_ url: URL) -> Verdict {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let len = (attrs[.size] as? NSNumber)?.uint64Value else {
            return Verdict(ok: false, reason: "file does not exist")
        }
        if len == 0 { return Verdict(ok: false, reason: "file is empty") }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Never fail a capture because the CHECKER could not run — an
            // unreadable file is a different problem, reported elsewhere.
            return Verdict(ok: true, reason: "")
        }
        defer { try? handle.close() }

        var state = mp4WalkInit()
        var steps = 0
        while !state.done {
            steps += 1
            if steps > maxSteps {
                return Verdict(ok: false, reason: "box chain did not terminate")
            }
            let chunk: Data
            do {
                try handle.seek(toOffset: state.offset)
                // A short read is not an error — it is how the core learns it
                // has reached the end of the file.
                chunk = try handle.read(upToCount: Int(state.want)) ?? Data()
            } catch {
                return Verdict(ok: true, reason: "")
            }
            state = mp4WalkStep(state: state, header: chunk, fileLen: len)
        }
        return Verdict(ok: state.ok, reason: state.reason)
    }
}
