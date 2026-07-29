import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

#if canImport(CoreBluetooth) && canImport(AVFAudio)

/// Entry point for Brilliant Labs glasses (Halo and Frame).
///
/// Usually you touch none of this. Pick the transport and the ordinary
/// `ExtentosGlasses` API drives the device:
///
/// ```swift
/// let glasses = Extentos.create(config: ExtentosConfig(transport: .brilliant))
/// ```
///
/// Add `NSBluetoothAlwaysUsageDescription` to your Info.plist — Halo streams
/// over its own BLE link rather than pairing as a headset, so iOS requires the
/// Bluetooth string even though this is, from the wearer's side, a microphone.
///
/// ## Parity note
///
/// Android ships Brilliant as a separate `com.extentos:glasses-brilliant`
/// artifact that self-registers, because `:glasses-core` there is deliberately
/// vendor-free and must stay that way. `GlassesCore` on iOS already depends on
/// Meta's Device Access Toolkit, so the same isolation does not exist to
/// protect, and a separate SPM product would buy nothing while cutting this
/// transport off from the shared recognition engine it reuses. Hence one
/// module here, two on Android — a deliberate delta, not drift.
///
/// PREVIEW: no Brilliant hardware has run this. The protocol beneath it is
/// verified byte-for-byte against the vendor's own implementation and the
/// handshake against a fake socket, but the CoreBluetooth layer has never met a
/// device, and unlike Android XR there is no emulator to meet either.
public enum ExtentosBrilliant {

    /// Is a Brilliant device connected to this phone right now?
    ///
    /// Ready-made for `ExtentosConfig.hasBrilliantDevice`:
    ///
    /// ```swift
    /// ExtentosConfig(hasBrilliantDevice: ExtentosBrilliant.hasConnectedDevice)
    /// ```
    ///
    /// Never scans and never prompts — see `CoreBluetoothBleBridge`
    /// `.hasConnectedDevice()` for why it reports false until Bluetooth has
    /// been authorized.
    public static func hasConnectedDevice() -> Bool {
        CoreBluetoothBleBridge.hasConnectedDevice()
    }

    /// A link for driving the device directly, outside the `ExtentosGlasses`
    /// API — the counterpart of Android's `ExtentosBrilliant.link(...)`.
    ///
    /// The bridge and the core each need the other, so the bridge is built
    /// first and attached once the core exists; hidden here so no caller has to
    /// know the order.
    public static func link(
        observer: BrilliantObserver,
        onLog: @escaping (String) -> Void = { _ in }
    ) -> BrilliantLink {
        let bridge = CoreBluetoothBleBridge(onLog: onLog)
        let core = BrilliantCore(bridge: bridge, observer: observer)
        bridge.attach(core)
        return BrilliantLink(core: core, bridge: bridge)
    }
}

/// One connection to one pair of Brilliant glasses.
///
/// Thin on purpose: everything it does is the core's, and it exists so a caller
/// does not have to hold two objects and remember which one to talk to.
public final class BrilliantLink: @unchecked Sendable {
    private let core: BrilliantCore
    private let bridge: CoreBluetoothBleBridge

    init(core: BrilliantCore, bridge: CoreBluetoothBleBridge) {
        self.core = core
        self.bridge = bridge
    }

    /// Scan and connect. `nameFilter` matches the BLE local name (e.g.
    /// "Halo AB") when several are in range; nil takes the first Brilliant
    /// device found.
    ///
    /// Reaching `LinkState.connected` means GATT is up, NOT that the device is
    /// usable — it is still running no Extentos code at that point. Wait for
    /// `LinkState.ready`, which the core reports once the on-device bundle is
    /// installed and has announced itself.
    ///
    /// TIMEOUTS ARE YOURS. The core carries no clock by design, so a device
    /// that connects and then goes quiet mid-handshake will sit in `connected`
    /// forever unless you give up and call `disconnect()`.
    public func connect(nameFilter: String? = nil) {
        core.connect(nameFilter: nameFilter)
    }

    public func disconnect() {
        core.disconnect()
    }

    /// Halo or Frame once connected, nil otherwise.
    public func device() -> BrilliantDevice? { core.device() }

    /// Send audio to the glasses' speaker. Fails on Frame, which has none.
    /// Sliced internally to the size the device accepts, because an oversized
    /// packet is dropped with no error at all.
    public func sendAudio(_ pcm: Data) throws { try core.sendAudio(pcm: pcm) }

    /// Run a Lua string on the glasses. Escape hatch for development; the
    /// bundle is what an app should be using.
    public func sendLua(_ source: String) throws { try core.sendLua(source: source) }

    /// Send a framed message to the on-device bundle.
    public func sendMessage(code: UInt8, payload: Data) throws {
        try core.sendMessage(code: code, payload: payload)
    }

    /// Release the socket. Safe to call more than once.
    public func close() { bridge.disconnect() }
}

#endif
