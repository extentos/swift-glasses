// WakeLedger — persistent, append-only observation of the wake chain
// ACROSS app launches. The session trace wipes per session and the ears
// tape wipes per launch, which made multi-launch wake failures exactly
// unobservable (b19 diagnosis: "fails a different way each time" with no
// surviving evidence). Measurement only — never decides, never blocks;
// write failures are swallowed. Rotates at 256KB.
//
// Pull:  python -m pymobiledevice3 apps pull <bundle> \
//          Documents/extentos-wake-ledger.txt <local>

import Foundation

final class WakeLedger: @unchecked Sendable {
    static let shared = WakeLedger()
    static let maxBytes: UInt64 = 256 * 1024

    private let lock = NSLock()
    private var handle: FileHandle?
    private var opened = false
    /// Distinguishes launches in the shared file; time-derived so two
    /// launches never collide within the rotation horizon.
    private let launchToken: String
    private let launchAtMs: Int64

    private init() {
        launchAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        launchToken = String(format: "%05x", Int(launchAtMs % 0xFFFFF))
    }

    func note(_ event: String) {
        let elapsedS = Double(Int64(Date().timeIntervalSince1970 * 1000) - launchAtMs) / 1000
        let line = String(format: "[%@ +%7.2fs] %@\n", launchToken, elapsedS, event)
        lock.lock()
        defer { lock.unlock() }
        openIfNeeded()
        guard let handle else { return }
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private func openIfNeeded() {
        guard !opened else { return }
        opened = true
        guard
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("extentos-wake-ledger.txt")
        else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        } else if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? UInt64,
                  size > Self.maxBytes {
            fm.createFile(atPath: url.path, contents: Data("(rotated)\n".utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? handle?.write(contentsOf: Data("── launch \(launchToken) @ \(stamp)\n".utf8))
    }
}
