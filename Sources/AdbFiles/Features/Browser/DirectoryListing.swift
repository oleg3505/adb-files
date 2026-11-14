import AdbKit

/// Lists directories on one device. `AdbSyncClient` in production, a scripted fake in tests.
protocol DirectoryListing: Sendable {
    func list(_ directory: String) async throws -> [RemoteFile]
    /// Ends any listing in flight (the device went away).
    func disconnect() async
}

extension AdbSyncClient: DirectoryListing {}
