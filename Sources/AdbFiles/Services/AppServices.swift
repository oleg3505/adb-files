import AdbKit
import Foundation
import Observation

/// One `AdbSyncClient` per device, created on first use and reused (it keeps one listing connection).
@MainActor
final class SyncClientRegistry {
    private var clients: [String: AdbSyncClient] = [:]

    func client(for serial: String) -> AdbSyncClient {
        if let existing = clients[serial] { return existing }
        let client = AdbSyncClient(serial: serial)
        clients[serial] = client
        return client
    }

    func existingClient(for serial: String) -> AdbSyncClient? { clients[serial] }
}

/// App-wide services shared by all windows: sync clients, the listing cache and transfers.
@Observable
@MainActor
final class AppServices {
    /// A finished upload; browsers showing `folder` on `serial` refresh.
    struct UploadEvent: Equatable {
        let id = UUID()
        let serial: String
        let folder: String
    }

    let listingCache = ListingCache()
    @ObservationIgnored let transfers: TransferQueue
    /// Last finished upload (observed by browsers).
    private(set) var lastUpload: UploadEvent?

    @ObservationIgnored private let clients: SyncClientRegistry
    @ObservationIgnored private var usableSerials: Set<String> = []
    @ObservationIgnored private var thumbnailServices: [String: ThumbnailService] = [:]

    init() {
        // Quick Look copies are only for this run.
        Task.detached(priority: .utility) { PreviewCache.clearAll() }
        let clients = SyncClientRegistry()
        self.clients = clients
        transfers = TransferQueue(engine: AdbTransferEngine { serial in await clients.client(for: serial) })
        transfers.onUploadFinished = { [weak self] serial, folder in
            guard let self else { return }
            let path = RemotePath.normalized(folder)
            Task { await self.listingCache.remove(serial: serial, path: path) }
            self.lastUpload = UploadEvent(serial: serial, folder: path)
        }
    }

    func syncClient(for serial: String) -> AdbSyncClient {
        clients.client(for: serial)
    }

    /// One thumbnail service per device (its own memory cache; reads on the interactive connection).
    func thumbnails(for serial: String) -> ThumbnailService {
        if let existing = thumbnailServices[serial] { return existing }
        let service = ThumbnailService(serial: serial, source: InteractiveThumbnailSource(client: clients.client(for: serial)))
        thumbnailServices[serial] = service
        return service
    }

    /// Called whenever the device list changes: transfers of devices that left (or became unusable) fail
    /// with Retry, and their connections are closed.
    func devicesChanged(_ devices: [Device]) {
        let usable = Set(devices.filter { $0.state.isUsable }.map(\.serial))
        for serial in usableSerials.subtracting(usable) {
            transfers.deviceGone(serial)
            if let thumbnails = thumbnailServices[serial] { Task { await thumbnails.cancelAll() } }
            if let client = clients.existingClient(for: serial) { Task { await client.disconnect() } }
        }
        usableSerials = usable
    }
}
