import AdbKit

/// Produces live device-list updates. `AdbHostClient` in production, a scripted fake in tests.
protocol DeviceTracking: Sendable {
    func trackDevices() -> AsyncThrowingStream<[Device], Error>
}

/// Starts the ADB server. `AdbServerLauncher` in production, a fake in tests.
protocol ServerStarting: Sendable {
    func startAdbServer() async throws
}

extension AdbHostClient: DeviceTracking {}

extension AdbServerLauncher: ServerStarting {
    func startAdbServer() async throws {
        try await startServer()
    }
}
