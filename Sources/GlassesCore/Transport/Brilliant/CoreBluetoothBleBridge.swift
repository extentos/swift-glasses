import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

// The BLE socket for Brilliant Labs glasses, and nothing more.
//
// Every decision about what the bytes MEAN lives in the Rust core
// (`BrilliantCore`): framing, chunking, reassembly, the Lua bundle, the connect
// handshake. This file scans, connects, discovers characteristics, moves bytes
// in both directions, and reports what it found — the exact same division the
// Android shell keeps. That split is the whole point of the design: the two
// platforms share one implementation of the protocol, so nothing about it can
// drift between them. Porting Brilliant to iOS was therefore the socket and
// nothing else, which is what `MigratedCoreTypes` predicted.
//
// PREVIEW: no Brilliant hardware has run this. The protocol underneath is
// verified byte-for-byte against the vendor's own implementation and the
// handshake against a fake socket, but the CoreBluetooth code here has by
// definition never met a device.

#if canImport(CoreBluetooth)

final class CoreBluetoothBleBridge: NSObject, BleBridge, @unchecked Sendable {

    /// Brilliant's GATT service. Scanning filters on it, which is also what
    /// lets the scan run while the app is backgrounded.
    static let service = CBUUID(string: "7A230001-5475-A6A4-654C-8431F6AD49C4")
    private static let txUuid = CBUUID(string: "7A230002-5475-A6A4-654C-8431F6AD49C4")
    private static let rxUuid = CBUUID(string: "7A230003-5475-A6A4-654C-8431F6AD49C4")

    /// Audio out. Present on Halo, ABSENT on Frame — which is how the two are
    /// told apart, since nothing on the wire names the model.
    private static let audioUuid = CBUUID(string: "7A230005-5475-A6A4-654C-8431F6AD49C4")

    /// Set once by `attach`. The bridge cannot be constructed with the core
    /// because the core is constructed with the bridge.
    private var core: BrilliantCore?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var audioChar: CBCharacteristic?
    private var deviceName: String?

    /// Set for the duration of one connect attempt; nil means "not scanning".
    private var nameFilter: String?
    private var wantsScan = false

    private let onLog: (String) -> Void
    private let queue = DispatchQueue(label: "com.extentos.brilliant.ble")

    /// CoreBluetooth serialises delegate callbacks onto `queue`, but `writeTx`
    /// is called from the core on whatever thread framed the message, so the
    /// queue state is touched from both. Guarded rather than assumed.
    private let lock = NSLock()
    private var txQueue: [Data] = []
    private var writeInFlight = false

    init(onLog: @escaping (String) -> Void = { _ in }) {
        self.onLog = onLog
        super.init()
    }

    /// Wire this bridge to the core that drives it. Call once, before `connect`.
    func attach(_ core: BrilliantCore) {
        self.core = core
    }

    func log(_ message: String) {
        onLog(message)
    }

    /// Is a Brilliant device already connected to this phone?
    ///
    /// The iOS counterpart of Android's bonded-device check, and deliberately
    /// NOT a scan: this backs transport resolution, which must be fast and
    /// must not burn radio on every launch.
    ///
    /// It answers a subtly different question than Android's, because iOS has
    /// no notion of a bonded-device list an app may read. `retrieveConnected
    /// Peripherals` returns peripherals connected to the SYSTEM — by any app,
    /// including Brilliant's own — that expose our service, which is the
    /// closest honest analogue.
    ///
    /// Returns false unless Bluetooth is already authorized. Instantiating a
    /// `CBCentralManager` is what triggers the permission prompt on iOS, and a
    /// prompt fired by `Extentos.create(...)` in an app that never asked for
    /// Bluetooth would be an ambush. `CBManager.authorization` is a static read
    /// that prompts nothing.
    static func hasConnectedDevice() -> Bool {
        guard CBManager.authorization == .allowedAlways else { return false }
        let probe = CBCentralManager(delegate: nil, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
        guard probe.state == .poweredOn else { return false }
        return !probe.retrieveConnectedPeripherals(withServices: [service]).isEmpty
    }

    // ── BleBridge ────────────────────────────────────────────────────────────

    func connect(nameFilter: String?) {
        lock.lock()
        self.nameFilter = nameFilter
        wantsScan = true
        lock.unlock()

        if central == nil {
            // Creating the manager triggers the authorization prompt if it has
            // not been answered. That is correct HERE — the app asked to
            // connect — and is why resolution-time eligibility uses the static
            // read above instead.
            central = CBCentralManager(delegate: self, queue: queue)
            // Scanning starts in centralManagerDidUpdateState once powered on.
            return
        }
        startScanIfReady()
    }

    func writeTx(packet: Data) {
        lock.lock()
        txQueue.append(packet)
        lock.unlock()
        pumpTx()
    }

    func writeAudio(packet: Data) {
        guard let p = peripheral, let c = audioChar else {
            onLog("audio write with no audio characteristic — Frame has no speaker")
            return
        }
        // Write WITHOUT response: audio is a stream, and waiting for an
        // acknowledgement per packet would not keep up. The core has already
        // sliced each packet to the size the device accepts, which matters
        // because an oversized one is dropped in silence.
        p.writeValue(packet, for: c, type: .withoutResponse)
    }

    func disconnect() {
        lock.lock()
        wantsScan = false
        txQueue.removeAll()
        writeInFlight = false
        lock.unlock()

        central?.stopScan()
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        txChar = nil
        audioChar = nil
    }

    // ── Internals ────────────────────────────────────────────────────────────

    private func startScanIfReady() {
        guard let c = central, c.state == .poweredOn else { return }
        lock.lock()
        let scan = wantsScan
        lock.unlock()
        guard scan else { return }
        c.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    private func pumpTx() {
        guard let p = peripheral, let c = txChar else { return }
        lock.lock()
        if writeInFlight || txQueue.isEmpty {
            lock.unlock()
            return
        }
        writeInFlight = true
        let next = txQueue.removeFirst()
        lock.unlock()
        // .withResponse so the device paces us: the reply drives the next
        // write. Bundle upload is dozens of packets and outrunning the
        // peripheral drops them.
        p.writeValue(next, for: c, type: .withResponse)
    }

    /// The link's ATT MTU, as the core means it.
    ///
    /// iOS negotiates the MTU itself — there is no `requestMtu` to call, which
    /// removes a whole ordering hazard the Android shell has to handle.
    /// `maximumWriteValueLength(for:)` reports the usable PAYLOAD, i.e.
    /// `ATT_MTU - 3`, so the +3 converts back to what the core's bounds are
    /// expressed in. Getting this wrong would size every packet three bytes
    /// too large, and Brilliant's transport drops an oversized packet with no
    /// error of any kind.
    private func negotiatedMtu() -> UInt16 {
        guard let p = peripheral else { return 23 }
        let payload = p.maximumWriteValueLength(for: .withResponse)
        return UInt16(clamping: payload + 3)
    }

    private func reportConnected() {
        core?.onConnected(info: LinkInfo(
            mtu: negotiatedMtu(),
            // The identity test: Halo carries the audio characteristic,
            // Frame does not.
            hasAudioOut: audioChar != nil,
            name: deviceName
        ))
    }
}

// ── CBCentralManagerDelegate ─────────────────────────────────────────────────

extension CoreBluetoothBleBridge: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanIfReady()
        case .unauthorized:
            onLog("bluetooth permission denied — add NSBluetoothAlwaysUsageDescription and grant it")
            core?.onDisconnected()
        case .poweredOff:
            onLog("bluetooth is off")
            core?.onDisconnected()
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        lock.lock()
        let filter = nameFilter
        lock.unlock()
        // A name filter is how a user picks between two pairs in the same room
        // ("Halo AB"). Absent, the first match wins.
        if let filter, name != filter { return }

        central.stopScan()
        lock.lock()
        wantsScan = false
        lock.unlock()

        deviceName = name
        // Retained deliberately: CoreBluetooth drops a peripheral it holds no
        // strong reference to, and the connection dies silently mid-handshake.
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        onLog("connect failed: \(error?.localizedDescription ?? "unknown")")
        core?.onDisconnected()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        lock.lock()
        txQueue.removeAll()
        writeInFlight = false
        lock.unlock()
        self.peripheral = nil
        txChar = nil
        audioChar = nil
        core?.onDisconnected()
    }
}

// ── CBPeripheralDelegate ─────────────────────────────────────────────────────

extension CoreBluetoothBleBridge: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            onLog("connected device has no Brilliant service")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [Self.txUuid, Self.rxUuid, Self.audioUuid],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let chars = service.characteristics ?? []
        txChar = chars.first { $0.uuid == Self.txUuid }
        audioChar = chars.first { $0.uuid == Self.audioUuid }
        guard let rx = chars.first(where: { $0.uuid == Self.rxUuid }), txChar != nil else {
            onLog("Brilliant service is missing TX or RX")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        // Subscribe BEFORE reporting the link up. The core's very first act is
        // to send a version probe, and its answer arrives as a notification —
        // enabling them afterwards races that reply and the handshake stalls on
        // a line that was already delivered.
        peripheral.setNotifyValue(true, for: rx)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.rxUuid else { return }
        if let error {
            onLog("could not subscribe to RX: \(error.localizedDescription)")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        reportConnected()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.rxUuid, let value = characteristic.value else { return }
        core?.onPacket(packet: value)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.txUuid else { return }
        if let error {
            onLog("tx write failed: \(error.localizedDescription)")
        }
        lock.lock()
        writeInFlight = false
        lock.unlock()
        pumpTx()
    }
}

#endif
