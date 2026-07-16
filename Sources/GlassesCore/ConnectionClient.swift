import Foundation

public protocol ConnectionClient: Sendable {
    var state: any ObservableState<GlassesState> { get }
    var simulatorHint: any ObservableState<SimulatorHint?> { get }

    @_spi(ExtentosEscapeHatch)
    var uiState: any ObservableState<ExtentosUiState> { get }

    func connect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError>
    func disconnect() async

    /// Forced reconnect: clean teardown, then a fresh connect. This is what
    /// pull-to-refresh on the connection page calls — `connect()` on top of
    /// a live session is not a supported path (Android parity:
    /// `ConnectionClient.reconnect`).
    func reconnect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError>
}

public extension ConnectionClient {
    func connect() async -> ExtentosResult<Void, ConnectError> {
        await connect(deviceId: nil)
    }

    func reconnect() async -> ExtentosResult<Void, ConnectError> {
        await reconnect(deviceId: nil)
    }

    // Default so existing conformers (test fakes) keep compiling; the real
    // client overrides this with a serialized implementation.
    func reconnect(deviceId: DeviceId?) async -> ExtentosResult<Void, ConnectError> {
        await disconnect()
        return await connect(deviceId: deviceId)
    }
}
