#if DEBUG
import Foundation
import SwiftUI
import GlassesCore

public struct ExtentosDebugPanel: View {
    private let glasses: any ExtentosGlasses

    public init(glasses: any ExtentosGlasses) {
        self.glasses = glasses
    }

    public var body: some View {
        Text("ExtentosDebugPanel — Phase 0 scaffold")
    }
}
#endif
