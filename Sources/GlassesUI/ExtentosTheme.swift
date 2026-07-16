import Foundation
import SwiftUI
import GlassesCore

public struct ExtentosTheme<Content: View>: View {
    private let appearance: Appearance
    private let content: () -> Content

    public init(appearance: Appearance = .default, @ViewBuilder content: @escaping () -> Content) {
        self.appearance = appearance
        self.content = content
    }

    public var body: some View {
        content().environment(\.extentosAppearance, appearance)
    }
}

private struct ExtentosAppearanceKey: EnvironmentKey {
    static let defaultValue: Appearance = .default
}

public extension EnvironmentValues {
    var extentosAppearance: Appearance {
        get { self[ExtentosAppearanceKey.self] }
        set { self[ExtentosAppearanceKey.self] = newValue }
    }
}
