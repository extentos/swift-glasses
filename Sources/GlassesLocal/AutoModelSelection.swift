// The iOS half of `local-auto`: it reads the two numbers the Rust core
// cannot read for itself and hands them to `resolveAutoModel`. The RULE lives
// in the core (`conversation/auto_model.rs`) so both platforms resolve
// identically — only these readings are platform-bound, and the LADDER
// NUMBERS are deliberately not shared: iOS runs 4-bit MLX checkpoints whose
// footprints differ from Android's GGUF quants (1.7B is ~1200 MB here versus
// ~2400 MB there). Copying either side's numbers onto the other is the bug
// this comment exists to prevent.
//
// The asymmetry the core's two-number contract encodes: iOS kills a process
// at a per-device ceiling (the iPhone-12 probe measured ~2.07 GB on 4 GB
// total — why the 3B rung jetsammed at load while 1.7B runs fine), whereas
// Android simply runs out of free RAM. Both map into "what can this device
// class sustainably give one app", so the CLASS budget decides and free
// memory may only force a one-session step down.

import Foundation
import GlassesCore
import HuggingFace

enum AutoModelSelection {

    /// Auto's floor is QUALITY, not fit: a rung that loads fine but cannot
    /// reliably call tools is a worse product than the cloud, so Auto skips
    /// it while an explicit pin still serves it. Gate-0 and the doc-16 sim
    /// matrix put the line here — Qwen3-0.6B does action tools 3/3 but read
    /// tools 0/2, and Qwen2.5-1.5B's ~75% ceiling lost to Qwen3-1.7B's 20/20
    /// at the same footprint.
    static let autoEligibleIds: Set<String> = [
        "local-qwen3-1.7b",
        "local-qwen3-4b",
        "local-qwen3-8b",
    ]

    /// Fraction of physical RAM taken as the per-process (jetsam) ceiling.
    ///
    /// A CALIBRATION KNOB, not a law. It matches the one device we have hard
    /// data for: the iPhone 12's measured ~2.07 GB ceiling on 4 GB physical
    /// is 51.75%. Erring low is the safe direction — it hands a user a
    /// smaller rung than their phone could have run, which nobody notices,
    /// rather than one that jetsams mid-load.
    private static let jetsamCeilingShare = 0.5

    /// Rungs the browser-sim inference machine actually hosts.
    ///
    /// ⚠️ HAND-SYNCED with `backend/sim-inference/llama-swap.yaml`, and with
    /// the Android set in `AutoModelSelection.kt`. The catalog is deliberately
    /// WIDER than this — the 8B rung ships for future high-memory devices but
    /// is not loaded on the sim machine — and resolving to a rung the machine
    /// doesn't host produces `404 model_not_found`, the same failure an
    /// unresolved `local-auto` produced on 2026-07-26.
    private static let simServedIds: Set<String> = [
        "local-qwen25-1.5b",
        "local-qwen3-1.7b",
        "local-qwen3-4b",
    ]

    /// Resolve `local-auto` for this device, right now.
    ///
    /// `servedRemotely` marks a browser-sim session. The ONLY thing it
    /// changes is where the weights live — the rule, the ladder and the
    /// device reading stay identical, so the developer's own phone resolves
    /// in the simulator exactly as it would on hardware.
    static func resolve(servedRemotely: Bool) -> AutoResolution {
        resolveAutoModel(
            ladder: ladder(servedRemotely: servedRemotely),
            device: deviceMemory(),
            servedRemotely: servedRemotely
        )
    }

    private static func ladder(servedRemotely: Bool) -> [LocalRung] {
        ExtentosLocalTier.requiredMb.map { id, requiredMb in
            LocalRung(
                modelId: id,
                requiredMb: UInt64(max(0, requiredMb)),
                autoEligible: autoEligibleIds.contains(id),
                // On the phone: is it downloaded. In the simulator: does the
                // inference machine HOST it — the same question, answered by
                // the substrate that actually holds the weights.
                weightsPresent: servedRemotely
                    ? Self.simServedIds.contains(id)
                    : weightsPresent(for: id)
            )
        }
    }

    private static func deviceMemory() -> DeviceMemory {
        let physicalMb = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let classBudgetMb = Int(Double(physicalMb) * jetsamCeilingShare)
        #if os(iOS)
        let availableMb = Int(os_proc_available_memory()) / (1024 * 1024)
        #else
        // macOS (harness/dev only) has no per-process ceiling to read; the
        // class budget is the honest stand-in so the resolver still runs.
        let availableMb = classBudgetMb
        #endif
        return DeviceMemory(
            classBudgetMb: UInt64(max(0, classBudgetMb)),
            availableNowMb: UInt64(max(0, availableMb))
        )
    }

    /// Are this rung's weights already in the Hub cache?
    ///
    /// iOS has no explicit model store: `loadModelContainer` downloads on
    /// first use. So presence is a cache probe — a resolved ref plus a
    /// non-empty snapshot directory. Anything less counts as absent, which
    /// fails toward the cloud and is the safe direction: serving from the
    /// gateway while a download lands is exactly Auto's intended behavior.
    private static func weightsPresent(for dashboardId: String) -> Bool {
        // MLX ids are "namespace/name" (e.g. mlx-community/Qwen3-1.7B-4bit);
        // Repo.ID takes the two halves separately.
        let repoPath = ExtentosLocalTier.brainConfig(for: dashboardId).modelId
        let parts = repoPath.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let repoId = Repo.ID(namespace: String(parts[0]), name: String(parts[1]))
        let cache = HubCache.default
        guard
            let commit = cache.resolveRevision(repo: repoId, kind: .model, ref: "main"),
            let snapshot = try? cache.snapshotPath(repo: repoId, kind: .model, commitHash: commit),
            let contents = try? FileManager.default.contentsOfDirectory(atPath: snapshot.path)
        else { return false }
        return !contents.isEmpty
    }
}
