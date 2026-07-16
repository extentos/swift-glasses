import Foundation
import SwiftUI
import GlassesCore

public final class ExtentosSceneObserver: NSObject, @unchecked Sendable {
    private let glasses: any ExtentosGlasses

    public init(glasses: any ExtentosGlasses) {
        self.glasses = glasses
        super.init()
    }

    public func scenePhaseChanged(to phase: ScenePhase) {
        // Phase 0 scaffold — no-op.
    }
}
