import Foundation

// Library version — stamped on every telemetry event, surfaced in debug
// logs and user-agent headers. Bumped at release time.

public enum LibraryVersion {
    // MUST bump in lockstep with android-library/gradle.properties
    // (extentos.version) at every release — the two SDKs version together.
    // The old "-pair" literals (iOS 1.1.36, Android 1.1.33) were stale by
    // 3 minors and disagreed with each other, mislabeling every telemetry
    // event (finding #12). Phase G formalizes via the swift-glasses publish.
    public static let version: String = "1.4.0"
}
