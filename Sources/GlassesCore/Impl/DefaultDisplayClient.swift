import Foundation
import os

/// Default `DisplayClient`: runs the builder into a `DisplayNode` tree,
/// normalizes it through the CORE policy (display/normalize.rs — sole-node
/// vs implicit column, DSP-17 mixed-video drop, shownKind), and hands the
/// root to the transport. Select/back events route back through the
/// builder's id → handler map.
///
/// Mirrors the post-hoist Kotlin `DefaultDisplayClient`, including the
/// local-media hosting paths (D5b): `video(clip:)` / `image(photo:)` host a
/// local capture at show() time and render the hosted URL, because the glasses
/// fetch http(s) only and the phone never proxies bytes.
final class DefaultDisplayClient: DisplayClient, @unchecked Sendable {

    private let transport: any GlassesTransport
    /// nil only in builds with no delivery wired; the local-media roots then
    /// degrade to a logged no-op rather than crashing.
    private let mediaDelivery: (any MediaDelivery)?
    private let log = Logger(subsystem: "com.extentos.glasses", category: "display")
    private let lock = NSLock()
    private var handlers: [String: @Sendable () -> Void] = [:]

    /// DSP-20 — the current root kind ("video", "flexBox", …) or nil when
    /// nothing is shown. The assistant runtime reads this for its
    /// glasses-state snapshot once the supplier wiring lands.
    private(set) var shownKind: String?

    init(transport: any GlassesTransport, mediaDelivery: (any MediaDelivery)? = nil) {
        self.transport = transport
        self.mediaDelivery = mediaDelivery
    }

    var isAvailable: Bool { transport.isDisplayCapable() }

    func show(onBack: (@Sendable () -> Void)?, content: (DisplayRootScope) -> Void) async {
        let scope = DisplayRootScope()
        content(scope)

        // video(clip): a locally-recorded clip hosted at show() time. Large clips
        // take a few seconds, so a "Preparing…" card holds the lens meanwhile.
        if let clip = scope.localClip {
            guard let uri = clip.uri else {
                log.warning("display.video_delivery_failed: the clip had no uri to host")
                return
            }
            let willUpload = mediaDelivery?.isHosted(uri) == false
            if willUpload {
                await transport.showDisplay(root: preparingVideoCard(), onSelect: { _ in }, onBack: onBack)
                lock.lock(); shownKind = "video_preparing"; lock.unlock()
                log.info("""
                    display.video_preparing: hosting the recorded clip for the lens — a few \
                    seconds for a large clip; call glasses.display.prepareVideo(clip) ahead of \
                    time to make this instant
                    """)
            }
            guard let url = await mediaDelivery?.hostedUrl(uri, kind: .video) else {
                // Don't leave "Preparing…" hanging on the lens if hosting failed.
                if willUpload {
                    await transport.clearDisplay()
                    lock.lock(); shownKind = nil; lock.unlock()
                }
                log.warning("""
                    display.video_delivery_failed: could not host the recorded clip for display \
                    — the glasses can only fetch an http(s) URL; check connectivity / clip size
                    """)
                return
            }
            lock.lock(); handlers = scope.handlers; lock.unlock()
            await transport.showDisplay(root: .video(url: url), onSelect: { _ in }, onBack: onBack)
            lock.lock(); shownKind = "video"; lock.unlock()
            return
        }

        // image(photo): the same shape on the image endpoint, sharing the
        // registry. Photos host in well under a second, so no "Preparing…" card;
        // a hosting failure degrades to a warning and no-op.
        if let photo = scope.localPhoto {
            guard let uri = photo.uri else {
                log.warning("display.image_delivery_failed: the photo had no uri to host")
                return
            }
            guard let url = await mediaDelivery?.hostedUrl(uri, kind: .image) else {
                log.warning("""
                    display.image_delivery_failed: could not host the photo for display — the \
                    glasses can only fetch an http(s) URL; check connectivity
                    """)
                return
            }
            lock.lock(); handlers = scope.handlers; lock.unlock()
            await transport.showDisplay(
                root: .image(url: url, size: .fill, cornerRadius: .none, align: .center),
                onSelect: { _ in },
                onBack: onBack
            )
            lock.lock(); shownKind = "image"; lock.unlock()
            return
        }

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

    // Pre-upload so a later show of the same clip is instant. Reuses the exact
    // hostedUrl path show() takes (single-flight, dedup), so a concurrent show
    // still uploads once. No-op (false) when delivery is unwired or uri is nil.
    func prepareVideo(clip: VideoClip) async -> Bool {
        guard let uri = clip.uri else { return false }
        return await mediaDelivery?.hostedUrl(uri, kind: .video) != nil
    }

    func forgetHostedVideo(clip: VideoClip) async {
        guard let uri = clip.uri else { return }
        await mediaDelivery?.forget(uri, kind: .video)
    }

    // Release the hosted copy of a photo when the app deletes it — the mirror
    // of forgetHostedVideo on the image endpoint, same shared registry.
    func forgetHostedImage(photo: Photo) async {
        guard let uri = photo.uri else { return }
        await mediaDelivery?.forget(uri, kind: .image)
    }

    func clear() async {
        lock.lock()
        handlers = [:]
        shownKind = nil
        lock.unlock()
        await transport.clearDisplay()
    }
}
