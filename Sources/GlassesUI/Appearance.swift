import Foundation
import SwiftUI

public struct Appearance: Sendable {
    public let colors: Colors
    public let typography: Typography
    public let shapes: Shapes

    public init(colors: Colors, typography: Typography, shapes: Shapes) {
        self.colors = colors
        self.typography = typography
        self.shapes = shapes
    }

    public struct Colors: Sendable {
        public let primary: Color
        public let surface: Color
        public let surfaceVariant: Color
        public let onSurface: Color
        public let onSurfaceSecondary: Color
        public let onSurfaceMuted: Color
        public let accent: Color
        public let success: Color
        public let warning: Color
        public let error: Color
        public let divider: Color

        public init(
            primary: Color,
            surface: Color,
            surfaceVariant: Color,
            onSurface: Color,
            onSurfaceSecondary: Color,
            onSurfaceMuted: Color,
            accent: Color,
            success: Color,
            warning: Color,
            error: Color,
            divider: Color
        ) {
            self.primary = primary
            self.surface = surface
            self.surfaceVariant = surfaceVariant
            self.onSurface = onSurface
            self.onSurfaceSecondary = onSurfaceSecondary
            self.onSurfaceMuted = onSurfaceMuted
            self.accent = accent
            self.success = success
            self.warning = warning
            self.error = error
            self.divider = divider
        }
    }

    public struct Typography: Sendable {
        public let sectionLabel: Font
        public let statusLabel: Font
        public let statusSub: Font
        public let metaLabel: Font
        public let metaValue: Font
        public let triggerPhrase: Font
        public let triggerBadge: Font
        public let capabilityName: Font
        public let pairingCode: Font
        // Per-style letter tracking (pt). SwiftUI `Font` cannot carry
        // letterSpacing the way Android's `TextStyle` does, so the tracked
        // eyebrow labels — the detail that reads "premium" — are stored here
        // and applied via `.tracking()` at the Text sites.
        public let sectionLabelTracking: CGFloat
        public let statusLabelTracking: CGFloat
        public let metaLabelTracking: CGFloat
        public let capabilityNameTracking: CGFloat
        public let pairingCodeTracking: CGFloat

        public init(
            sectionLabel: Font,
            statusLabel: Font,
            statusSub: Font,
            metaLabel: Font,
            metaValue: Font,
            triggerPhrase: Font,
            triggerBadge: Font,
            capabilityName: Font,
            pairingCode: Font = .system(size: 38, weight: .bold, design: .monospaced),
            sectionLabelTracking: CGFloat = 1.4,
            statusLabelTracking: CGFloat = -0.2,
            metaLabelTracking: CGFloat = 1.2,
            capabilityNameTracking: CGFloat = 0.2,
            pairingCodeTracking: CGFloat = 6
        ) {
            self.sectionLabel = sectionLabel
            self.statusLabel = statusLabel
            self.statusSub = statusSub
            self.metaLabel = metaLabel
            self.metaValue = metaValue
            self.triggerPhrase = triggerPhrase
            self.triggerBadge = triggerBadge
            self.capabilityName = capabilityName
            self.pairingCode = pairingCode
            self.sectionLabelTracking = sectionLabelTracking
            self.statusLabelTracking = statusLabelTracking
            self.metaLabelTracking = metaLabelTracking
            self.capabilityNameTracking = capabilityNameTracking
            self.pairingCodeTracking = pairingCodeTracking
        }
    }

    public struct Shapes: Sendable {
        public let card: RoundedRectangle
        public let section: RoundedRectangle
        public let chip: RoundedRectangle

        public init(card: RoundedRectangle, section: RoundedRectangle, chip: RoundedRectangle) {
            self.card = card
            self.section = section
            self.chip = chip
        }
    }

    // Premium dark default — matches the Android Appearance.Default premium
    // spec byte-for-byte (brand-blue accent spent deliberately, NOT green
    // sprayed everywhere; semantic green/amber live only in the status dots).
    public static let `default` = Appearance(
        colors: Colors(
            primary: Color(red: 0.23, green: 0.51, blue: 0.96),           // #3B82F6 brand blue
            surface: Color(red: 0.039, green: 0.039, blue: 0.059),        // #0A0A0F base
            surfaceVariant: Color(red: 0.082, green: 0.082, blue: 0.094), // ~#15151A card plane
            onSurface: .white,
            onSurfaceSecondary: Color(red: 0.64, green: 0.65, blue: 0.68),// ~#A4A6AE
            onSurfaceMuted: Color(red: 0.42, green: 0.45, blue: 0.50),    // ~#6B7280
            accent: Color(red: 0.27, green: 0.55, blue: 0.97),            // ~#458CF7 brand blue
            success: Color(red: 0.20, green: 0.78, blue: 0.35),           // ~#34C759
            warning: Color(red: 0.98, green: 0.69, blue: 0.21),           // ~#FAB036
            error: Color(red: 0.94, green: 0.27, blue: 0.27),             // #EF4444
            divider: Color(red: 0.16, green: 0.16, blue: 0.19)            // ~#292930
        ),
        typography: Typography(
            sectionLabel: .system(size: 12, weight: .semibold),
            statusLabel: .system(size: 18, weight: .semibold),
            statusSub: .system(size: 13, weight: .regular),
            metaLabel: .system(size: 11, weight: .medium),
            metaValue: .system(size: 13, weight: .regular),
            triggerPhrase: .system(size: 15, weight: .medium),
            triggerBadge: .system(size: 11, weight: .medium),
            capabilityName: .system(size: 12, weight: .medium)
        ),
        shapes: Shapes(
            card: RoundedRectangle(cornerRadius: 18, style: .continuous),
            section: RoundedRectangle(cornerRadius: 22, style: .continuous),
            chip: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    )
}
