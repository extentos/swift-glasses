import Foundation

// `glasses.display` — the native display surface for display-capable
// glasses (Meta Ray-Ban Display). A declarative tree per show{} call;
// whole-display replace; select/back events route to the builder's
// handlers. Mirrors `android-library/.../DisplayClient.kt`.
//
// The tree vocabulary (`DisplayNode`), the canonical wire JSON, and the
// root-normalization policy (sole-video rule, implicit column, mixed-drop,
// shownKind) are ALL core-owned — this surface is a thin builder + client.
//
// Degradation contract: a display call on a device without a display does
// nothing, silently — guard UX with `isAvailable`, but a missed guard is
// never a crash.
//
// v1 scope note: local-media roots (`video(clip:)` / `image(photo:)`)
// need the hosted-media delivery port and land with D5b; URL-based video
// and images work today.

public protocol DisplayClient: Sendable {

    /// Whether the CONNECTED glasses have a display (Ray-Ban Display: yes;
    /// Ray-Ban Meta: no). In the sim it follows the session's selected
    /// device model LIVE.
    var isAvailable: Bool { get }

    /// Render a declarative tree as the full display content (whole-display
    /// replace; latest show wins). `onBack` handles the back gesture for
    /// THIS show (view-contextual).
    func show(onBack: (@Sendable () -> Void)?, content: (DisplayRootScope) -> Void) async

    /// Clear the display (and drop the current show's handlers).
    func clear() async
}

public extension DisplayClient {
    func show(content: (DisplayRootScope) -> Void) async {
        await show(onBack: nil, content: content)
    }
}

/// Builder scope for one `show{}` tree. Node methods mirror the Kotlin
/// builder; ids for tappable nodes auto-assign (stable within a show).
public class DisplayScope {
    var nodes: [DisplayNode] = []
    var handlers: [String: @Sendable () -> Void] = [:]
    private var nextId = 0

    func claimId() -> String {
        nextId += 1
        return "n\(nextId)"
    }

    /// A run of text.
    public func text(
        _ text: String,
        style: TextStyle = .body,
        color: TextColor = .primary,
        align: Alignment = .start
    ) {
        nodes.append(.text(text: text, style: style, color: color, align: align))
    }

    /// An image by URL (the glasses fetch http(s) themselves).
    public func image(
        url: String,
        size: ImageSize = .fill,
        cornerRadius: CornerRadius = .none,
        align: Alignment = .center
    ) {
        nodes.append(.image(url: url, size: size, cornerRadius: cornerRadius, align: align))
    }

    /// A tappable button; `onClick` fires on a real tap or a sim-injected
    /// select.
    public func button(
        _ text: String,
        style: ButtonStyle = .primary,
        icon: String? = nil,
        align: Alignment = .center,
        onClick: @escaping @Sendable () -> Void
    ) {
        let id = claimId()
        handlers[id] = onClick
        nodes.append(.button(id: id, text: text, style: style, icon: icon, align: align))
    }

    /// A vendor icon by name (validated by the transport).
    public func icon(
        _ name: String,
        style: IconStyle = .filled,
        align: Alignment = .center
    ) {
        nodes.append(.icon(name: name, style: style, align: align))
    }

    /// A layout container.
    public func flexBox(
        direction: Direction = .column,
        mainAlign: Alignment = .start,
        crossAlign: Alignment = .stretch,
        gap: UInt32 = 0,
        padding: EdgeInsets = EdgeInsets(top: 0, right: 0, bottom: 0, left: 0),
        background: Background = .none,
        onClick: (@Sendable () -> Void)? = nil,
        content: (DisplayScope) -> Void
    ) {
        let child = DisplayScope()
        child.nextIdBase(from: self)
        content(child)
        adoptIds(from: child)
        var clickId: String?
        if let onClick {
            let id = claimId()
            handlers[id] = onClick
            clickId = id
        }
        handlers.merge(child.handlers) { current, _ in current }
        nodes.append(.flexBox(
            direction: direction,
            mainAlign: mainAlign,
            crossAlign: crossAlign,
            gap: gap,
            padding: padding,
            background: background,
            onClick: clickId,
            children: child.nodes
        ))
    }

    // Keep nested-scope ids globally unique within one show.
    private func nextIdBase(from parent: DisplayScope) {
        nextId = parent.nextId + 1000
    }

    private func adoptIds(from child: DisplayScope) {
        nextId = max(nextId, child.nextId)
    }
}

/// The root scope — adds the full-surface video root (root-only per
/// DSP-17; the core normalization drops mixed-case videos with a WARN).
public final class DisplayRootScope: DisplayScope {

    /// A hosted video as the FULL display surface (must be the sole
    /// top-level node).
    public func video(url: String) {
        nodes.append(.video(url: url))
    }
}
