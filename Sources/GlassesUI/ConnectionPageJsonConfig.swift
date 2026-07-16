import Foundation
import SwiftUI

// Reads `extentos.connection-page.json` from the host app's main bundle
// and merges it with `Appearance.default` + `SectionVisibility()`
// field-by-field. Mirrors Android's ConnectionPageJsonConfig — same JSON
// schema, same precedence (code > JSON > defaults), same hex-color shape.
//
// Unknown fields are silently ignored (additive-only contract per
// `LIBRARY_API_SWIFT.md` § Layer 3 escape hatch).

struct ConnectionPageJsonConfig {
    let sections: PartialSections?
    let appearance: PartialAppearance?

    static let resourceName = "extentos.connection-page"

    /// Reads + parses the bundled JSON, if present and well-formed.
    /// Failures are silent — the host app keeps rendering with defaults.
    static func load(bundle: Bundle = .main) -> ConnectionPageJsonConfig? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data: data)
    }

    static func parse(data: Data) -> ConnectionPageJsonConfig? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let root = raw as? [String: Any] else {
            return nil
        }
        // schemaVersion is informational; future versions still parse via
        // the additive-only contract.
        _ = root["schemaVersion"] as? Int

        let sections: PartialSections? = (root["sections"] as? [String: Any]).map(PartialSections.init)
        let appearance: PartialAppearance? = (root["appearance"] as? [String: Any]).map(PartialAppearance.init)
        return ConnectionPageJsonConfig(sections: sections, appearance: appearance)
    }
}

// MARK: - Partials with merge

struct PartialSections {
    let capabilities: Bool?
    let voiceCommands: Bool?
    let toggles: Bool?

    init(_ obj: [String: Any]) {
        self.capabilities = obj["capabilities"] as? Bool
        self.voiceCommands = obj["voiceCommands"] as? Bool
        self.toggles = obj["toggles"] as? Bool
    }

    func merge(_ base: SectionVisibility) -> SectionVisibility {
        SectionVisibility(
            capabilities: capabilities ?? base.capabilities,
            voiceCommands: voiceCommands ?? base.voiceCommands,
            toggles: toggles ?? base.toggles
        )
    }
}

struct PartialAppearance {
    let colors: PartialColors?
    let typography: PartialTypography?
    let shapes: PartialShapes?

    init(_ obj: [String: Any]) {
        self.colors = (obj["colors"] as? [String: Any]).map(PartialColors.init)
        self.typography = (obj["typography"] as? [String: Any]).map(PartialTypography.init)
        self.shapes = (obj["shapes"] as? [String: Any]).map(PartialShapes.init)
    }

    func merge(_ base: Appearance) -> Appearance {
        Appearance(
            colors: colors?.merge(base.colors) ?? base.colors,
            typography: typography?.merge(base.typography) ?? base.typography,
            shapes: shapes?.merge(base.shapes) ?? base.shapes
        )
    }
}

struct PartialColors {
    let primary: Color?
    let surface: Color?
    let surfaceVariant: Color?
    let onSurface: Color?
    let onSurfaceSecondary: Color?
    let onSurfaceMuted: Color?
    let accent: Color?
    let success: Color?
    let warning: Color?
    let error: Color?
    let divider: Color?

    init(_ obj: [String: Any]) {
        self.primary = ColorParse.hex(obj["primary"] as? String)
        self.surface = ColorParse.hex(obj["surface"] as? String)
        self.surfaceVariant = ColorParse.hex(obj["surfaceVariant"] as? String)
        self.onSurface = ColorParse.hex(obj["onSurface"] as? String)
        self.onSurfaceSecondary = ColorParse.hex(obj["onSurfaceSecondary"] as? String)
        self.onSurfaceMuted = ColorParse.hex(obj["onSurfaceMuted"] as? String)
        self.accent = ColorParse.hex(obj["accent"] as? String)
        self.success = ColorParse.hex(obj["success"] as? String)
        self.warning = ColorParse.hex(obj["warning"] as? String)
        self.error = ColorParse.hex(obj["error"] as? String)
        self.divider = ColorParse.hex(obj["divider"] as? String)
    }

    func merge(_ base: Appearance.Colors) -> Appearance.Colors {
        Appearance.Colors(
            primary: primary ?? base.primary,
            surface: surface ?? base.surface,
            surfaceVariant: surfaceVariant ?? base.surfaceVariant,
            onSurface: onSurface ?? base.onSurface,
            onSurfaceSecondary: onSurfaceSecondary ?? base.onSurfaceSecondary,
            onSurfaceMuted: onSurfaceMuted ?? base.onSurfaceMuted,
            accent: accent ?? base.accent,
            success: success ?? base.success,
            warning: warning ?? base.warning,
            error: error ?? base.error,
            divider: divider ?? base.divider
        )
    }
}

struct PartialTextStyle {
    let family: String?
    let weight: Int?
    let size: CGFloat?

    init(_ obj: [String: Any]) {
        self.family = obj["family"] as? String
        self.weight = (obj["weight"] as? NSNumber)?.intValue
        self.size = (obj["size"] as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    /// Reconstructs a `Font` from base + overrides. Family is honored via
    /// `Font.custom(_:size:)` if non-empty; weight maps Material's 100-900
    /// to SwiftUI `Font.Weight`; size in points (matches Android's `sp`
    /// numeric convention).
    func merge(_ base: Font) -> Font {
        // Without introspecting `base` (Font isn't decomposable), if any
        // override is set we synthesize a fresh Font; otherwise leave base
        // alone. Default size pulled from a sensible 14pt fallback when
        // size isn't supplied — same fallback Android takes via copy().
        if family == nil && weight == nil && size == nil { return base }
        let pt = size ?? 14
        var f: Font
        if let family = family, !family.isEmpty {
            f = Font.custom(family, size: pt)
        } else {
            f = .system(size: pt)
        }
        if let w = weight {
            f = f.weight(weightFromInt(w))
        }
        return f
    }

    private func weightFromInt(_ w: Int) -> Font.Weight {
        switch w {
        case ..<150: return .thin
        case 150..<250: return .ultraLight
        case 250..<350: return .light
        case 350..<450: return .regular
        case 450..<550: return .medium
        case 550..<650: return .semibold
        case 650..<750: return .bold
        case 750..<850: return .heavy
        default: return .black
        }
    }
}

struct PartialTypography {
    let sectionLabel: PartialTextStyle?
    let statusLabel: PartialTextStyle?
    let statusSub: PartialTextStyle?
    let metaLabel: PartialTextStyle?
    let metaValue: PartialTextStyle?
    let triggerPhrase: PartialTextStyle?
    let triggerBadge: PartialTextStyle?
    let capabilityName: PartialTextStyle?

    init(_ obj: [String: Any]) {
        self.sectionLabel = (obj["sectionLabel"] as? [String: Any]).map(PartialTextStyle.init)
        self.statusLabel = (obj["statusLabel"] as? [String: Any]).map(PartialTextStyle.init)
        self.statusSub = (obj["statusSub"] as? [String: Any]).map(PartialTextStyle.init)
        self.metaLabel = (obj["metaLabel"] as? [String: Any]).map(PartialTextStyle.init)
        self.metaValue = (obj["metaValue"] as? [String: Any]).map(PartialTextStyle.init)
        self.triggerPhrase = (obj["triggerPhrase"] as? [String: Any]).map(PartialTextStyle.init)
        self.triggerBadge = (obj["triggerBadge"] as? [String: Any]).map(PartialTextStyle.init)
        self.capabilityName = (obj["capabilityName"] as? [String: Any]).map(PartialTextStyle.init)
    }

    func merge(_ base: Appearance.Typography) -> Appearance.Typography {
        Appearance.Typography(
            sectionLabel: sectionLabel?.merge(base.sectionLabel) ?? base.sectionLabel,
            statusLabel: statusLabel?.merge(base.statusLabel) ?? base.statusLabel,
            statusSub: statusSub?.merge(base.statusSub) ?? base.statusSub,
            metaLabel: metaLabel?.merge(base.metaLabel) ?? base.metaLabel,
            metaValue: metaValue?.merge(base.metaValue) ?? base.metaValue,
            triggerPhrase: triggerPhrase?.merge(base.triggerPhrase) ?? base.triggerPhrase,
            triggerBadge: triggerBadge?.merge(base.triggerBadge) ?? base.triggerBadge,
            capabilityName: capabilityName?.merge(base.capabilityName) ?? base.capabilityName
        )
    }
}

struct PartialShapes {
    let card: RoundedRectangle?
    let section: RoundedRectangle?
    let chip: RoundedRectangle?

    init(_ obj: [String: Any]) {
        self.card = PartialShapes.shape(obj["card"] as? [String: Any])
        self.section = PartialShapes.shape(obj["section"] as? [String: Any])
        self.chip = PartialShapes.shape(obj["chip"] as? [String: Any])
    }

    private static func shape(_ obj: [String: Any]?) -> RoundedRectangle? {
        guard let obj = obj,
              let r = (obj["cornerRadius"] as? NSNumber)?.doubleValue else { return nil }
        return RoundedRectangle(cornerRadius: CGFloat(r), style: .continuous)
    }

    func merge(_ base: Appearance.Shapes) -> Appearance.Shapes {
        Appearance.Shapes(
            card: card ?? base.card,
            section: section ?? base.section,
            chip: chip ?? base.chip
        )
    }
}

// MARK: - Color parsing

enum ColorParse {
    /// Accepts `#RRGGBB` or `#AARRGGBB`. Returns nil for any other shape.
    static func hex(_ raw: String?) -> Color? {
        guard var raw = raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard let v = UInt64(raw, radix: 16) else { return nil }
        switch raw.count {
        case 6:
            let r = Double((v >> 16) & 0xFF) / 255.0
            let g = Double((v >> 8) & 0xFF) / 255.0
            let b = Double(v & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b, opacity: 1.0)
        case 8:
            let a = Double((v >> 24) & 0xFF) / 255.0
            let r = Double((v >> 16) & 0xFF) / 255.0
            let g = Double((v >> 8) & 0xFF) / 255.0
            let b = Double(v & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b, opacity: a)
        default:
            return nil
        }
    }
}
