import AdbKit
import Observation

/// App-wide services shared by all windows: one sync client per device and the listing cache.
@Observable
@MainActor
final class AppServices {
    let listingCache = ListingCache()
    @ObservationIgnored private var syncClients: [String: AdbSyncClient] = [:]

    /// The sync client for a device; created on first use and reused (it keeps one listing connection).
    func syncClient(for serial: String) -> AdbSyncClient {
        if let existing = syncClients[serial] { return existing }
        let client = AdbSyncClient(serial: serial)
        syncClients[serial] = client
        return client
    }
}
