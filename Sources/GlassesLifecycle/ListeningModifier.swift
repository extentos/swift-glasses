import Foundation
import SwiftUI
import GlassesCore

public enum ListeningMode: Sendable {
    case always
    case fromToggles
    case disabled
}

public extension View {
    func extentosListening(
        _ glasses: any ExtentosGlasses,
        mode: ListeningMode = .fromToggles
    ) -> some View {
        self.modifier(ExtentosListeningModifier(glasses: glasses, mode: mode))
    }
}

private struct ExtentosListeningModifier: ViewModifier {
    let glasses: any ExtentosGlasses
    let mode: ListeningMode

    func body(content: Content) -> some View {
        content
    }
}
