import Foundation
import GlassesCore

public final class FakeExtentosGlasses: ExtentosGlasses, @unchecked Sendable {
    public static func make(
        initialState: GlassesState = .notRegistered
    ) -> FakeExtentosGlasses {
        FakeExtentosGlasses()
    }

    public var connection: any ConnectionClient {
        fatalError("FakeExtentosGlasses.connection not implemented in Phase 0 scaffold")
    }
    public var camera: any CameraClient {
        fatalError("FakeExtentosGlasses.camera not implemented in Phase 0 scaffold")
    }
    public var audio: any AudioClient {
        fatalError("FakeExtentosGlasses.audio not implemented in Phase 0 scaffold")
    }
    public var runtime: any RuntimeClient {
        fatalError("FakeExtentosGlasses.runtime not implemented in Phase 0 scaffold")
    }
    public var toggles: any ToggleClient {
        fatalError("FakeExtentosGlasses.toggles not implemented in Phase 0 scaffold")
    }
    public var voice: any VoiceClient {
        fatalError("FakeExtentosGlasses.voice not implemented in Phase 0 scaffold")
    }
    public var telemetry: any TelemetryClient {
        fatalError("FakeExtentosGlasses.telemetry not implemented in Phase 0 scaffold")
    }
    public var observability: any ObservabilityClient {
        fatalError("FakeExtentosGlasses.observability not implemented in Phase 0 scaffold")
    }
    // Phase 4 — `assistant` surface is mandatory on `ExtentosGlasses`
    // (always-on per synthesis). Phase 0 fake fatalErrors like the
    // other unimplemented surfaces; real tests use a custom-built
    // `DefaultAssistantClient` against stub audio/transport.
    public var usedCapabilities: [DeclaredCapability] { [] }
    public var capabilities: DeviceCapabilitySet {
        metaCapabilityProfile(displayCapable: false)
    }

    public var display: any DisplayClient {
        FakeDisplayClient()
    }

    public var assistant: any AssistantClient {
        fatalError("FakeExtentosGlasses.assistant not implemented in Phase 0 scaffold")
    }

    public func shutdown() async {}

    public func emitEvent(_ event: RuntimeEvent) {
        // Phase 0 scaffold — no-op.
    }
}


/// No-display fake: isAvailable false; show/clear are silent no-ops (the
/// decided degradation contract).
final class FakeDisplayClient: DisplayClient, @unchecked Sendable {
    var isAvailable: Bool { false }
    func show(onBack: (@Sendable () -> Void)?, content: (DisplayRootScope) -> Void) async {}
    func clear() async {}
}
