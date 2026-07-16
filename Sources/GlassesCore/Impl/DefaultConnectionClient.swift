import Foundation

final class DefaultConnectionClient: ConnectionClient, @unchecked Sendable {
    private let transport: any GlassesTransport
    private let stateRef: MutableState<GlassesState>
    private let simulatorHintRef: MutableState<SimulatorHint?>
    private let uiStateRef: MutableState<ExtentosUiState>

    init(transport: any GlassesTransport, initialUiState: ExtentosUiState) {
        self.transport = transport
        self.stateRef = MutableState(.notRegistered)
        self.simulatorHintRef = MutableState(nil)
        self.uiStateRef = MutableState(initialUiState)

        // Wire transport events → state / hint.
        Task.detached { [stateRef, simulatorHintRef, transport] in
            for await event in transport.events {
                switch event {
                case .stateChanged(let next):
                    stateRef.set(next)
                case .simulatorHintChanged(let hint):
                    simulatorHintRef.set(hint)
                case .hardwareAlertEvent, .errorEvent, .transcriptEmitted:
                    break
                }
            }
        }
    }

    var state: any ObservableState<GlassesState> { stateRef }
    var simulatorHint: any ObservableState<SimulatorHint?> { simulatorHintRef }

    var uiState: any ObservableState<ExtentosUiState> { uiStateRef }

    func connect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError> {
        await transport.connect(deviceId: deviceId)
    }

    // Serialize so overlapping pull-to-refresh / custom reconnect calls don't
    // interleave one caller's disconnect with another's connect (Android
    // parity: reconnectMutex in DefaultConnectionClient.kt). Task-chained
    // because a lock can't be held across await: the NSLock only guards the
    // tail swap; each reconnect awaits its predecessor before touching the
    // transport.
    private let reconnectLock = NSLock()
    private var reconnectTail: Task<Void, Never>?

    func reconnect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError> {
        reconnectLock.lock()
        let prior = reconnectTail
        let work = Task { [transport] () -> ExtentosResult<Void, ConnectError> in
            await prior?.value
            await transport.disconnect()
            return await transport.connect(deviceId: deviceId)
        }
        reconnectTail = Task { _ = await work.value }
        reconnectLock.unlock()
        return await work.value
    }

    func disconnect() async {
        await transport.disconnect()
    }

    func updateUiState(_ transform: (ExtentosUiState) -> ExtentosUiState) {
        uiStateRef.update(transform)
    }
}
