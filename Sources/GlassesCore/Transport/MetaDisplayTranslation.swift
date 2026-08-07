import Foundation

// MWDAT ships iOS-only frameworks, so the whole translation is iOS-gated —
// the same guard MetaHardwareBridge and RealMetaTransport use. Without it a
// macOS `swift build` fails on the import alone.
#if os(iOS)
import MWDATDisplay

/// Translation from the vendor-agnostic `DisplayNode` tree (extentos-core) to
/// Meta's `MWDATDisplay` view components — the Swift half of Android's
/// `MetaDisplayTranslation.kt`.
///
/// One `DisplayNode` in, Meta view values out. No state, no I/O. Interactive
/// nodes surface their stable `id` through `onSelect`; that is the developer's
/// `onClick`, fired by Meta's button / container press (Neural Band or captouch)
/// on real glasses, or by the simulator's injected select.
///
/// This file exists because iOS shipped without it. Android's `glasses-meta`
/// has depended on `mwdat-display` since the display work landed; the iOS
/// `Package.swift` pulled `MWDATCore` and `MWDATCamera` and stopped there, so
/// `glasses.display.show()` on real Meta hardware resolved to the transport
/// protocol's default no-op and rendered nothing, silently. Not a Meta
/// limitation — `MWDATDisplay` has been a product of the same pinned 0.8.0
/// package the whole time.
///
/// # Where the two SDKs genuinely differ
///
/// Android's builder is scope-based (`flexBox { text(...) }` calling into a
/// receiver); iOS composes VALUES through a result builder. The output is the
/// same tree, but two differences are real and are handled here rather than
/// papered over:
///
///  * **`alignSelf` exists only on `FlexBox` in the iOS SDK.** Android accepts
///    it on text, image, button and icon. A leaf carrying a non-default
///    alignment is therefore wrapped in a single-child `FlexBox` that carries
///    it. Default-aligned leaves emit bare, so ordinary trees produce the same
///    structure on both platforms and only the trees that need the wrapper pay
///    for it.
///  * **Icon names have three plausible spellings.** Both platforms expose the
///    same 116 icons. Android resolves `IconName.valueOf(UPPER_SNAKE)`; the iOS
///    enum's RAW VALUES are snake_case (`"arrow_left"`), which is not the same
///    thing as its Swift case names (`arrowLeft`) — and the `.swiftinterface`
///    elides the raw values, so reading the header suggests the case name is the
///    raw value. It is not; verified against the runtime. All three spellings
///    resolve here, so one developer string works on both platforms whichever
///    docs they read.
///
/// Video is the third difference and it is a simplification: Meta's iOS SDK
/// makes `VideoPlayer` a `DisplayableView` you `send()` like any other root,
/// where Android constructs a player inside `sendContent` and then `play()`s it.
/// Same constraint underneath — video is root-only, never a child (DSP-17).

/// Render `node` as the root view handed to `Display.send(_:)`.
///
/// Returns `nil` for a root this SDK cannot present. Today that is only a
/// nested-video tree that reached here by hand — the DSL blocks it at compile
/// time and `show()` drops it at runtime.
func metaRootView(_ node: DisplayNode, onSelect: @escaping @Sendable (String) -> Void) -> (any DisplayableView)? {
    switch node {
    case let .flexBox(direction, mainAlign, crossAlign, gap, wrap, _, padding, background, onClick, children):
        return metaFlexBox(
            direction: direction,
            mainAlign: mainAlign,
            crossAlign: crossAlign,
            gap: gap,
            wrap: wrap,
            padding: padding,
            background: background,
            onClick: onClick,
            children: children,
            onSelect: onSelect
        )
    // DSP-17: a root video is the one true-motion channel this hardware gives
    // third-party content. On iOS it IS the root view, sent like any other.
    case let .video(url):
        return VideoPlayer(provider: .uri(url), codec: .mp4)
    // A leaf at the root: wrap it in a column so the root is always a container,
    // matching the Android translation exactly.
    default:
        let child = metaComponent(node, onSelect: onSelect)
        return FlexBox(direction: .column) {
            for c in (child.map { [$0] } ?? []) { c }
        }
    }
}

/// Build the `FlexBox` for a container node, applying the modifiers the iOS SDK
/// exposes as chained calls rather than initializer arguments.
private func metaFlexBox(
    direction: Direction,
    mainAlign: Alignment,
    crossAlign: Alignment,
    gap: UInt32,
    wrap: Bool,
    padding: EdgeInsets,
    background: Background,
    onClick: String?,
    children: [DisplayNode],
    onSelect: @escaping @Sendable (String) -> Void
) -> FlexBox {
    let components = children.compactMap { metaComponent($0, onSelect: onSelect) }
    var box = FlexBox(
        direction: direction.toMeta(),
        spacing: CGFloat(gap),
        alignment: mainAlign.toMeta(),
        crossAlignment: crossAlign.toMeta(),
        wrap: wrap,
        // Our four-edge insets map onto Meta's leading/trailing (LTR), the same
        // mapping Android makes onto paddingStart / paddingEnd.
        padding: MWDATDisplay.EdgeInsets(
            top: CGFloat(padding.top),
            bottom: CGFloat(padding.bottom),
            leading: CGFloat(padding.left),
            trailing: CGFloat(padding.right)
        )
    ) {
        for c in components { c }
    }
    box = box.background(background.toMeta())
    if let id = onClick {
        box = box.onTap { onSelect(id) }
    }
    return box
}

/// Render `node` as a child component, or `nil` when it cannot be one.
private func metaComponent(_ node: DisplayNode, onSelect: @escaping @Sendable (String) -> Void) -> (any ViewComponent)? {
    switch node {
    case let .flexBox(direction, mainAlign, crossAlign, gap, wrap, _, padding, background, onClick, children):
        return metaFlexBox(
            direction: direction,
            mainAlign: mainAlign,
            crossAlign: crossAlign,
            gap: gap,
            wrap: wrap,
            padding: padding,
            background: background,
            onClick: onClick,
            children: children,
            onSelect: onSelect
        )

    case let .text(text, style, color, align):
        return aligned(Text(text, style: style.toMeta(), color: color.toMeta()), align)

    case let .image(url, size, cornerRadius, align):
        return aligned(
            Image(uri: url, sizePreset: size.toMeta(), cornerRadius: cornerRadius.toMeta()),
            align
        )

    case let .button(id, text, style, icon, align):
        return aligned(
            Button(
                label: text,
                style: style.toMeta(),
                iconName: icon.flatMap(metaIconName),
                onClick: { onSelect(id) }
            ),
            align
        )

    case let .icon(name, style, align):
        // An unrecognised icon renders as nothing rather than throwing —
        // display degradation never crashes the host app.
        guard let resolved = metaIconName(name) else { return nil }
        return aligned(Icon(name: resolved, style: style.toMeta()), align)

    // Meta `video` is root-only; a nested video cannot render. The DSL stops it
    // at compile time and show() drops it at runtime (DSP-17), so this arm is
    // defensive only, for hand-built wire trees.
    case .video:
        return nil
    }
}

/// Apply per-child alignment, which the iOS SDK offers only on `FlexBox`.
///
/// A default-aligned component is returned untouched so ordinary trees keep the
/// same structure on both platforms; anything else gets a one-child container
/// carrying the alignment, which is the only way to express it here.
private func aligned(_ component: any ViewComponent, _ align: Alignment) -> any ViewComponent {
    guard align != .start else { return component }
    return FlexBox(direction: .column) { component }.alignSelf(align.toMeta())
}

// MARK: - core → Meta enum mappers (1:1 by name, except TextStyle.caption → meta)

private extension Direction {
    func toMeta() -> MWDATDisplay.Direction {
        switch self {
        case .row: return .row
        case .column: return .column
        case .rowReverse: return .rowReverse
        case .columnReverse: return .columnReverse
        }
    }
}

private extension Alignment {
    func toMeta() -> MWDATDisplay.Alignment {
        switch self {
        case .start: return .start
        case .center: return .center
        case .end: return .end
        case .stretch: return .stretch
        }
    }
}

private extension ButtonStyle {
    func toMeta() -> MWDATDisplay.ButtonStyle {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        case .outline: return .outline
        }
    }
}

private extension CornerRadius {
    func toMeta() -> MWDATDisplay.CornerRadius {
        switch self {
        case .none: return .none
        case .small: return .small
        case .medium: return .medium
        }
    }
}

private extension Background {
    func toMeta() -> MWDATDisplay.Background {
        switch self {
        case .none: return .none
        case .card: return .card
        }
    }
}

private extension IconStyle {
    func toMeta() -> MWDATDisplay.IconStyle {
        switch self {
        case .filled: return .filled
        case .outline: return .outline
        }
    }
}

private extension ImageSize {
    func toMeta() -> MWDATDisplay.ImageSize {
        switch self {
        case .icon: return .icon
        case .fill: return .fill
        }
    }
}

private extension TextColor {
    func toMeta() -> MWDATDisplay.TextColor {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        }
    }
}

private extension TextStyle {
    func toMeta() -> MWDATDisplay.TextStyle {
        switch self {
        case .heading: return .heading
        case .body: return .body
        // Our `caption` is Meta's `meta` text style (small / de-emphasized).
        case .caption: return .meta
        }
    }
}

/// Resolve a developer-supplied icon string to a Meta `IconName`, or `nil` when
/// it is not one of the 116 platform icons.
///
/// Tolerant of every spelling a developer could reasonably arrive at, because
/// the alternative is an icon that silently vanishes on one platform:
///
///  * `"arrow_left"` — the iOS enum's actual raw value, and the lowercased form
///    of Android's constant.
///  * `"ARROW_LEFT"` — what the Android docs show, since Android resolves with
///    `IconName.valueOf(trim().uppercase())`.
///  * `"arrowLeft"` — the Swift CASE name, which is what an iOS developer reads
///    off the header. It is NOT the raw value; the `.swiftinterface` prints the
///    cases without their raw values, so a strict `IconName(rawValue:)` rejects
///    exactly the spelling the header advertises. Verified against the runtime
///    rather than the header, which is the only way to catch this.
func metaIconName(_ raw: String) -> MWDATDisplay.IconName? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let direct = MWDATDisplay.IconName(rawValue: trimmed) { return direct }
    if let lowered = MWDATDisplay.IconName(rawValue: trimmed.lowercased()) { return lowered }
    // camelCase → snake_case, for the Swift case-name spelling.
    var snake = ""
    for ch in trimmed {
        if ch.isUppercase && !snake.isEmpty {
            snake.append("_")
        }
        snake.append(contentsOf: ch.lowercased())
    }
    return MWDATDisplay.IconName(rawValue: snake)
}

#endif // os(iOS)
