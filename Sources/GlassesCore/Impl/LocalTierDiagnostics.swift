// Local realtime v2 — session trace for hardware iteration.
//
// iOS syslog marks app log content <private> over USB, so "barge-in felt
// sloppy" was unmeasurable from the outside. The local provider records its
// decisions here — machine transitions, classifier verdicts, per-turn
// latency spans — and the host app (Glassnotes Lab) renders + shares the
// report. Debug/dogfood surface: bounded ring, no PII beyond what the
// session itself heard, cleared per session.

import Foundation
import os

public final class LocalTierDiagnostics: @unchecked Sendable {

    public static let shared = LocalTierDiagnostics()

    /// PUBLIC os_log so the line survives into the USB syslog (`pymobiledevice3
    /// syslog live`) — NSLog/print are redacted to <private> there, which is
    /// exactly what made hardware runs unobservable from the dev box. This is
    /// a debug/dogfood surface; lines carry what the session itself heard.
    private static let log = Logger(subsystem: "com.extentos.glasses", category: "localtier")

    public struct Entry: Sendable, Identifiable {
        public let id: Int
        /// ms since session start.
        public let atMs: Int64
        public let line: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextId = 0
    private var sessionStartMs: Int64 = 0
    private static let cap = 600

    /// Called by the provider at session start; wipes the previous session.
    public func beginSession(label: String) {
        lock.lock()
        entries.removeAll()
        nextId = 0
        sessionStartMs = Self.nowMs()
        lock.unlock()
        record(label)
    }

    public func record(_ line: String) {
        lock.lock()
        let at = sessionStartMs == 0 ? 0 : Self.nowMs() - sessionStartMs
        entries.append(Entry(id: nextId, atMs: at, line: line))
        nextId += 1
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
        lock.unlock()
        Self.log.info("[trace +\(Double(at) / 1000.0, format: .fixed(precision: 2))s] \(line, privacy: .public)")
        schedulePersist()
    }

    // ── Pull-anytime file (USB house-arrest: apps afc <bundle> pull …) ────

    private var persistScheduled = false
    private static let fileURL: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("extentos-session-trace.txt")

    /// Debounced full rewrite — the ring is small and runs end sparsely.
    private func schedulePersist() {
        lock.lock()
        let schedule = !persistScheduled
        persistScheduled = true
        lock.unlock()
        guard schedule, let url = Self.fileURL else { return }
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.lock.lock()
            self.persistScheduled = false
            self.lock.unlock()
            try? self.report().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Shareable plain-text report (the probe-report pattern).
    public func report() -> String {
        let lines = snapshot().map { entry in
            String(format: "%8.2fs  %@", Double(entry.atMs) / 1000.0, entry.line)
        }
        return "Extentos local tier — session trace\n\n" + lines.joined(separator: "\n")
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
