import Foundation
import SwiftUI
@_spi(ExtentosEscapeHatch) import GlassesCore

// SwiftUI port of the Android ExtentosConnectionPage — a faithful visual
// match of `android-library/.../ui/ExtentosConnectionPage.kt` (the premium
// redesign): a two-tile status block (Meta-View auth + glasses connection)
// with icon chips and breathing status dots + a firmware/runtime footer,
// equal-weight capability tiles (icon over label, dimmed when the device
// can't provide it), the "Say to me" voice section, and icon-chip toggle
// rows — all on hairline-bordered dark cards. The DECISIONS (3-state
// collapse, capability availability, indicator colors, firmware sanitize)
// are core-owned (capability/mod.rs); this file is the rendering layer.

public struct ExtentosConnectionPage: View {
    private let glasses: any ExtentosGlasses
    private let config: ConnectionPageConfig
    private let jsonConfig: ConnectionPageJsonConfig?

    public init(glasses: any ExtentosGlasses, config: ConnectionPageConfig = ConnectionPageConfig()) {
        self.glasses = glasses
        self.config = config
        self.jsonConfig = ConnectionPageJsonConfig.load()
    }

    public var body: some View {
        ConnectionPageBody(glasses: glasses, config: config, jsonConfig: jsonConfig)
    }
}

public struct ConnectionPageConfig: Sendable {
    public var sections: SectionVisibility
    public init(sections: SectionVisibility = SectionVisibility()) {
        self.sections = sections
    }
}

public struct SectionVisibility: Sendable {
    public var capabilities: Bool
    /// "Say to me" section between Capabilities and Toggles — every
    /// `glasses.voice.onPhrase` / `registerHint` entry, display-only.
    public var voiceCommands: Bool
    public var toggles: Bool
    public init(capabilities: Bool = true, voiceCommands: Bool = true, toggles: Bool = true) {
        self.capabilities = capabilities
        self.voiceCommands = voiceCommands
        self.toggles = toggles
    }
}

// MARK: - Internals

// A 1px white-alpha ring — the Linear/Vercel "hairline" that gives every
// dark surface a crisp premium edge (matches Android's `Hairline`).
private let hairline = Color.white.opacity(0.07)

private extension View {
    func hairlineBorder<S: InsettableShape>(_ shape: S) -> some View {
        overlay(shape.stroke(hairline, lineWidth: 1))
    }
}

private struct ConnectionPageBody: View {
    let glasses: any ExtentosGlasses
    let config: ConnectionPageConfig
    let jsonConfig: ConnectionPageJsonConfig?

    @StateObject private var model: ExtentosStateModel
    @State private var pairing: PairingHint?
    @Environment(\.extentosAppearance) private var envAppearance

    init(glasses: any ExtentosGlasses, config: ConnectionPageConfig, jsonConfig: ConnectionPageJsonConfig?) {
        self.glasses = glasses
        self.config = config
        self.jsonConfig = jsonConfig
        _model = StateObject(wrappedValue: ExtentosStateModel(glasses: glasses))
    }

    var body: some View {
        let baseAppearance = envAppearance
        let appearance = jsonConfig?.appearance?.merge(baseAppearance) ?? baseAppearance
        let sections = jsonConfig?.sections?.merge(config.sections) ?? config.sections
        let state = model.state

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let pairing = pairing {
                    ExtentosPairingScreen(
                        code: pairing.code,
                        expiresAtMs: pairing.expiresAtMs,
                        appearance: appearance
                    )
                }

                StatusBlock(state: state, appearance: appearance)

                if sections.capabilities && !state.capabilities.isEmpty {
                    SectionLabel(text: "Capabilities", appearance: appearance)
                    CapabilitiesGrid(capabilities: state.capabilities, appearance: appearance)
                }

                if sections.voiceCommands && !state.voiceHints.isEmpty {
                    SectionLabel(text: "Say to me", appearance: appearance)
                    VoiceCommandsSection(hints: state.voiceHints, appearance: appearance)
                }

                if sections.toggles && !state.toggles.isEmpty {
                    SectionLabel(text: "Toggles", appearance: appearance)
                    ForEach(state.toggles) { toggle in
                        ToggleRow(toggle: toggle, appearance: appearance) { newValue in
                            let key = toggle.id
                            let kind = toggle.kind
                            let g = glasses
                            Task {
                                await g.toggles.update { old in
                                    var values = old.values
                                    switch kind {
                                    case .listeningModeEnum:
                                        values[key] = .string(newValue ? "always_on" : "off")
                                    case .bool:
                                        values[key] = .bool(newValue)
                                    }
                                    return Toggles(values: values)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(appearance.colors.surface.ignoresSafeArea())
        .environment(\.extentosAppearance, appearance)
        .refreshable {
            // Pull-to-refresh = forced reconnect: clean teardown then a fresh
            // connect, serialized in the client (mirrors Android's
            // `connection.reconnect()`). A bare `connect()` on top of a live
            // session re-entered DAT session establishment and could bounce a
            // healthy connection to not-connected.
            _ = await glasses.connection.reconnect()
        }
        .task {
            let hintStream = glasses.connection.simulatorHint.stream
            for await hint in hintStream {
                if case .awaitingPair(let code, let expiresAtMs) = hint {
                    pairing = PairingHint(code: code, expiresAtMs: expiresAtMs)
                } else if pairing != nil {
                    pairing = nil
                }
            }
        }
    }
}

private struct PairingHint: Equatable {
    let code: String
    let expiresAtMs: Int64
}

// MARK: - Status block (two tiles + footer, one hairline card)

private struct StatusBlock: View {
    let state: ExtentosUiState
    let appearance: Appearance

    var body: some View {
        let summary = connectionSummary(state: state.connection)
        let connectionSub = [summary.headline, summary.help]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        VStack(spacing: 0) {
            StatusTile(
                icon: "infinity",   // Meta infinity mark stand-in (asset TODO)
                iconTint: appearance.colors.accent,
                title: "Meta View",
                sub: authDescribe(state.auth),
                indicator: authIndicator(state.auth, appearance),
                pulsing: false,
                appearance: appearance
            )
            rowDivider
            StatusTile(
                icon: "eye.fill",
                iconTint: appearance.colors.onSurfaceSecondary,
                title: state.deviceName ?? "Glasses",
                sub: connectionSub,
                indicator: connectionColor(state.connection, appearance),
                pulsing: connectionIndicatorPulsing(state: state.connection),
                appearance: appearance
            )
            rowDivider
            HStack(spacing: 10) {
                Text("FIRMWARE")
                    .font(appearance.typography.metaLabel)
                    .tracking(appearance.typography.metaLabelTracking)
                    .foregroundColor(appearance.colors.onSurfaceMuted)
                Text(cleanFirmware(raw: state.firmware) ?? "—")
                    .font(appearance.typography.metaValue)
                    .foregroundColor(appearance.colors.onSurface)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(runtimeStateLabel(state.connection))
                    .font(appearance.typography.metaValue)
                    .foregroundColor(appearance.colors.onSurfaceSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(appearance.colors.surfaceVariant)
        .clipShape(appearance.shapes.section)
        .hairlineBorder(appearance.shapes.section)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(appearance.colors.divider)
            .frame(height: 1)
            .padding(.horizontal, 18)
    }
}

private struct StatusTile: View {
    let icon: String
    let iconTint: Color
    let title: String
    let sub: String?
    let indicator: Color
    let pulsing: Bool
    let appearance: Appearance

    var body: some View {
        HStack(spacing: 14) {
            ChipBox(appearance: appearance) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(iconTint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(appearance.typography.statusLabel)
                    .tracking(appearance.typography.statusLabelTracking)
                    .foregroundColor(appearance.colors.onSurface)
                if let sub = sub, !sub.isEmpty {
                    Text(sub)
                        .font(appearance.typography.statusSub)
                        .foregroundColor(appearance.colors.onSurfaceSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusDot(color: indicator, pulsing: pulsing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

// A premium status light: a solid core inside a soft same-color halo;
// breathes while the link is working (amber states), steady otherwise.
private struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var dim = false

    var body: some View {
        let alpha = (pulsing && dim) ? 0.35 : 1.0
        ZStack {
            Circle().fill(color).frame(width: 18, height: 18).opacity(0.18 * alpha)
            Circle().fill(color).frame(width: 9, height: 9).opacity(alpha)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                dim = true
            }
        }
    }
}

// A 40pt rounded icon container (surface fill, hairline ring) — the recurring
// leading affordance on every status / voice / toggle row.
private struct ChipBox<Content: View>: View {
    let appearance: Appearance
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: 40, height: 40)
            .background(appearance.colors.surface)
            .clipShape(appearance.shapes.chip)
            .hairlineBorder(appearance.shapes.chip)
    }
}

private struct SectionLabel: View {
    let text: String
    let appearance: Appearance

    var body: some View {
        Text(text.uppercased())
            .font(appearance.typography.sectionLabel)
            .tracking(appearance.typography.sectionLabelTracking)
            .foregroundColor(appearance.colors.onSurfaceMuted)
            .padding(.leading, 4)
            .padding(.top, 4)
    }
}

// MARK: - Capabilities (equal-weight icon tiles, dimmed when unavailable)

private struct CapabilitiesGrid: View {
    let capabilities: [CapabilityEntry]
    let appearance: Appearance

    var body: some View {
        HStack(spacing: 12) {
            ForEach(capabilities) { cap in
                CapabilityTile(capability: cap, appearance: appearance)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct CapabilityTile: View {
    let capability: CapabilityEntry
    let appearance: Appearance

    var body: some View {
        let active = capability.availability == .active
        VStack(spacing: 8) {
            Image(systemName: capabilityIcon(capability.kind))
                .font(.system(size: 24))
                .foregroundColor(active ? appearance.colors.onSurface : appearance.colors.onSurfaceMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(appearance.colors.surfaceVariant)
                .clipShape(appearance.shapes.card)
                .hairlineBorder(appearance.shapes.card)
            Text(capability.label)
                .font(appearance.typography.capabilityName)
                .tracking(appearance.typography.capabilityNameTracking)
                .lineLimit(1)
                .foregroundColor(active ? appearance.colors.onSurfaceSecondary : appearance.colors.onSurfaceMuted)
        }
        .opacity(active ? 1.0 : 0.5)
    }
}

// MARK: - Voice ("Say to me")

private struct VoiceCommandsSection: View {
    let hints: [VoiceHint]
    let appearance: Appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(hints) { hint in
                VoiceHintRow(hint: hint, appearance: appearance)
                ForEach(hint.stops, id: \.self) { stop in
                    StopHintRow(phrase: stop, appearance: appearance)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.colors.surfaceVariant)
        .clipShape(appearance.shapes.card)
        .hairlineBorder(appearance.shapes.card)
    }
}

private struct VoiceHintRow: View {
    let hint: VoiceHint
    let appearance: Appearance

    var body: some View {
        HStack(spacing: 14) {
            ChipBox(appearance: appearance) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20))
                    .foregroundColor(appearance.colors.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\u{201C}\(hint.phrase)\u{201D}")
                    .font(appearance.typography.triggerPhrase)
                    .foregroundColor(appearance.colors.onSurface)
                if hint.label != hint.phrase {
                    Text(hint.label)
                        .font(appearance.typography.metaValue)
                        .foregroundColor(appearance.colors.onSurfaceSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct StopHintRow: View {
    let phrase: String
    let appearance: Appearance

    var body: some View {
        Text("\u{2514} stop: \u{201C}\(phrase)\u{201D}")
            .font(appearance.typography.metaValue)
            .italic()
            .foregroundColor(appearance.colors.onSurfaceMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 30)
            .padding(.trailing, 16)
            .padding(.top, 2)
            .padding(.bottom, 8)
    }
}

// MARK: - Toggles

private struct ToggleRow: View {
    let toggle: ToggleEntry
    let appearance: Appearance
    let onChange: (Bool) -> Void

    @State private var localValue: Bool

    init(toggle: ToggleEntry, appearance: Appearance, onChange: @escaping (Bool) -> Void) {
        self.toggle = toggle
        self.appearance = appearance
        self.onChange = onChange
        _localValue = State(initialValue: toggle.value)
    }

    var body: some View {
        HStack(spacing: 14) {
            ChipBox(appearance: appearance) {
                Image(systemName: toggleIcon(toggle.icon))
                    .font(.system(size: 20))
                    .foregroundColor(localValue ? appearance.colors.onSurface : appearance.colors.onSurfaceMuted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(toggle.label)
                    .font(appearance.typography.triggerPhrase)
                    .foregroundColor(appearance.colors.onSurface)
                if let desc = toggle.description, !desc.isEmpty {
                    Text(desc)
                        .font(appearance.typography.metaValue)
                        .foregroundColor(appearance.colors.onSurfaceSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { localValue },
                set: { newValue in
                    localValue = newValue
                    onChange(newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: appearance.colors.accent))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(appearance.colors.surfaceVariant)
        .clipShape(appearance.shapes.card)
        .hairlineBorder(appearance.shapes.card)
        .onChange(of: toggle.value) { newValue in
            localValue = newValue
        }
    }
}

// MARK: - Local mappings (rendering-only; decisions are core-owned)

private func authDescribe(_ status: AuthStatus) -> String {
    switch status {
    case .authorized: return "Authorized"
    case .required: return "Authorization required"
    case .error: return "Authorization error"
    }
}

private func authIndicator(_ status: AuthStatus, _ appearance: Appearance) -> Color {
    switch status {
    case .authorized: return appearance.colors.success
    case .required: return appearance.colors.warning
    case .error: return appearance.colors.error
    }
}

private func connectionColor(_ state: GlassesState, _ appearance: Appearance) -> Color {
    switch connectionIndicatorRole(state: state) {
    case .success: return appearance.colors.success
    case .warning: return appearance.colors.warning
    case .muted: return appearance.colors.onSurfaceMuted
    }
}

private func runtimeStateLabel(_ state: GlassesState) -> String {
    guard case .active(let active) = state else { return "Idle" }
    switch active {
    case .sessionActive: return "Running"
    case .streamActive: return "Streaming"
    case .connected: return "Ready"
    }
}

private func capabilityIcon(_ kind: CapabilityKind) -> String {
    switch kind {
    case .camera: return "camera.fill"
    case .microphone: return "mic.fill"
    case .speaker: return "speaker.wave.2.fill"
    case .location: return "location.fill"
    case .notifications: return "bell.fill"
    case .display: return "ipad"
    case .other: return "questionmark"
    }
}

private func toggleIcon(_ token: String) -> String {
    switch token {
    case "mic": return "mic.fill"
    case "camera": return "camera.fill"
    case "speaker", "volume_up": return "speaker.wave.2.fill"
    case "bell": return "bell.fill"
    case "shield": return "shield.fill"
    default: return "questionmark"
    }
}
