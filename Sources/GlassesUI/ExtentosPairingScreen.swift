import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// SwiftUI mirror of Android's ExtentosPairingScreen.kt (Compose). Rendered
// only when `simulatorHint = .awaitingPair(code:expiresAtMs:)` — i.e., the
// Track B+ MCP localhost probe didn't resolve and the dev needs to type a
// 5-char code into `extentos.com/s/<sessionId>` to claim this socket.
//
// Auto-bind path never surfaces this screen.
//
// Spec: SIMULATOR_PROTOCOL.md § Pairing Code, PERSISTENT_DEV_SESSION.md.

public struct ExtentosPairingScreen: View {
    private let code: String
    private let expiresAtMs: Int64
    private let appearance: Appearance

    public init(
        code: String,
        expiresAtMs: Int64,
        appearance: Appearance = .default
    ) {
        self.code = code
        self.expiresAtMs = expiresAtMs
        self.appearance = appearance
    }

    @State private var nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    @State private var copyConfirm: Bool = false

    public var body: some View {
        let secondsLeft = max(0, (expiresAtMs - nowMs) / 1000)
        let expired = secondsLeft <= 0

        VStack(alignment: .center, spacing: 14) {
            Text("PAIR THIS DEVICE")
                .font(appearance.typography.sectionLabel)
                .foregroundColor(appearance.colors.onSurfaceMuted)

            Text("Open the simulator and enter the code below.")
                .font(appearance.typography.statusSub)
                .foregroundColor(appearance.colors.onSurfaceSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Text(code.uppercased())
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .tracking(8)
                    .foregroundColor(appearance.colors.onSurface)
                Button(action: copy) {
                    Image(systemName: copyConfirm ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(appearance.colors.onSurfaceSecondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copyConfirm ? "Copied" : "Copy pairing code")
            }
            .padding(.vertical, 6)

            if expired {
                Text("Code expired — restart the app to get a new one.")
                    .font(appearance.typography.metaValue)
                    .foregroundColor(appearance.colors.error)
            } else {
                Text("Expires in \(formatDuration(secondsLeft))")
                    .font(appearance.typography.metaValue)
                    .foregroundColor(appearance.colors.onSurfaceMuted)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(appearance.colors.surfaceVariant)
        .clipShape(appearance.shapes.section)
        .task(id: expiresAtMs) {
            // Tick once per second to drive the countdown. Cancels when the
            // view goes away or when expiresAtMs changes (re-pair).
            while !Task.isCancelled {
                nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        #endif
        copyConfirm = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copyConfirm = false
        }
    }

    private func formatDuration(_ s: Int64) -> String {
        let mins = s / 60
        let secs = s % 60
        if mins > 0 { return "\(mins)m \(secs)s" }
        return "\(secs)s"
    }
}
