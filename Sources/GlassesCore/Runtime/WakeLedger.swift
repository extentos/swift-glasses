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

    /// True when this process is an XCTest runner.
    ///
    /// Computed once: `NSClassFromString` is cheap but this sits on the wake
    /// path, and the answer cannot change within a process. XCTest is not linked
    /// into a shipping app, so on a real device this is always false and the
    /// ledger behaves exactly as before — the check costs a nil comparison.
    private static let isUnderXCTest = NSClassFromString("XCTestCase") != nil

    private func openIfNeeded() {
        guard !opened else { return }
        opened = true
        // Never touch the filesystem under XCTest.
        //
        // This header promises "never blocks", and until 2026-07-30 that was
        // untrue in one environment: the self-hosted CI runner overrides HOME and
        // runs in its own security session, so `documentDirectory` resolves
        // somewhere that STALLS rather than failing. The stall happens while
        // `note()` holds `lock`, and `note()` is called from `doWakeLocked()`
        // inside the assistant's LifecycleSerializer — so one stuck stat wedged
        // every subsequent lifecycle operation, the test's expectation never
        // fulfilled, and the iOS gate burned its 75-minute budget with no output.
        // Four consecutive runs ended `cancelled` and it read as CI flakiness.
        //
        // A measurement facility must never be able to wedge the thing it
        // measures, and this one hid it perfectly: every write is `try?`, so the
        // failure had no voice. Disabling it under test restores the gate at zero
        // risk to device behaviour — a test run has no multi-launch wake history
        // to preserve, which is the ledger's whole reason to exist.
        //
        // NOTE this is the containment, not the cure. On a real device the same
        // shape is still reachable: a slow or unwritable documents directory
        // would stall the wake path and present as "the assistant never wakes",
        // silently. Fixing that means moving the I/O off the lock, which is a
        // change to a hardware-verified path and is scheduled deliberately with a
        // glasses re-verification rather than smuggled in here.
        guard !Self.isUnderXCTest else { return }
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
