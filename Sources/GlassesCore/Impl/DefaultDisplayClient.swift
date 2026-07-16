import Foundation
import os

/// Default `DisplayClient`: runs the builder into a `DisplayNode` tree,
/// normalizes it through the CORE policy (display/normalize.rs — sole-node
/// vs implicit column, DSP-17 mixed-video drop, shownKind), and hands the
/// root to the transport. Select/back events route back through the
/// builder's id → handler map.
///
/// Mirrors the post-hoist Kotlin `DefaultDisplayClient` (minus the
/// local-media hosting paths, which land with D5b's MediaDelivery port).
final class DefaultDisplayClient: DisplayClient, @unchecked Sendable {

    private let transport: any GlassesTransport
    private let log = Logger(subsystem: "com.extentos.glasses", category: "display")
    private let lock = NSLock()
    private var handlers: [String: @Sendable () -> Void] = [:]

    /// DSP-20 — the current root kind ("video", "flexBox", …) or nil when
    /// nothing is shown. The assistant runtime reads this for its
    /// glasses-state snapshot once the supplier wiring lands.
    private(set) var shownKind: String?

    init(transport: any GlassesTransport) {
        self.transport = transport
    }

    var isAvailable: Bool { transport.isDisplayCapable() }

    func show(onBack: (@Sendable () -> Void)?, content: (DisplayRootScope) -> Void) async {
        let scope = DisplayRootScope()
        content(scope)

        // Root normalization + shownKind vocabulary are core-owned.
        let normalized = normalizeDisplayRoot(nodes: scope.nodes)
        if let warn = normalized.droppedVideoWarn {
            log.warning("display.video_dropped: \(warn.reason, privacy: .public)")
        }
        lock.lock()
        handlers = scope.handlers
        lock.unlock()

        await transport.showDisplay(
            root: normalized.root,
            onSelect: { [weak self] id in
                guard let self else { return }
                self.lock.lock()
                let handler = self.handlers[id]
                self.lock.unlock()
                handler?()
            },
            onBack: onBack
        )
        lock.lock()
        shownKind = normalized.shownKind
        lock.unlock()
    }

    func clear() async {
        lock.lock()
        handlers = [:]
        shownKind = nil
        lock.unlock()
        await transport.clearDisplay()
    }
}
