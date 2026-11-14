import AdbKit
import Foundation
import Observation
import os

/// File browser state for one device in one window: current folder, history, rows, sort and filter.
@Observable
@MainActor
final class BrowserStore {
    enum Phase: Equatable {
        case loading
        case loaded
        case empty
        case denied
        case notFound
        case failed(String)
    }

    static let startPath = "/sdcard"

    let serial: String
    private(set) var path: String
    private(set) var phase: Phase = .loading {
        didSet {
            if phase != oldValue { Logger.ui.info("browser phase=\(String(describing: self.phase), privacy: .public)") }
        }
    }
    /// Sorted, filtered rows for the table.
    private(set) var rows: [FileRow] = []
    /// Bumped whenever `rows` changes, so the table reloads only then.
    private(set) var rowsVersion = 0
    /// Selected row paths.
    private(set) var selection: Set<String> = []

    var sort = FileSort() {
        didSet {
            guard sort != oldValue else { return }
            Logger.ui.info("sort key=\(self.sort.key.rawValue, privacy: .public) asc=\(self.sort.ascending)")
            rebuildRows()
        }
    }
    var showHidden = false {
        didSet {
            guard showHidden != oldValue else { return }
            Logger.ui.info("hidden=\(self.showHidden)")
            rebuildRows()
        }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { RemotePath.parent(of: path) != nil }

    @ObservationIgnored private let listing: any DirectoryListing
    @ObservationIgnored private let cache: ListingCache
    @ObservationIgnored private let pipeline: RowPipeline
    @ObservationIgnored private var files: [RemoteFile] = []
    /// Display rows for `files`, built once per listing; sorting and filtering reuse them.
    @ObservationIgnored private var builtRows: [FileRow] = []
    // Observed (not ignored): toolbar and Go-menu enablement depend on them.
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Bumped on every rows publish and every re-arrange request; an arrange whose epoch is stale is dropped,
    /// so a slow refresh and a quick header click can't overwrite each other out of order.
    @ObservationIgnored private var arrangeEpoch = 0
    @ObservationIgnored private var started = false

    init(
        serial: String, listing: any DirectoryListing, cache: ListingCache, startPath: String = BrowserStore.startPath,
        pipeline: RowPipeline = RowPipeline()
    ) {
        self.serial = serial
        self.listing = listing
        self.cache = cache
        self.pipeline = pipeline
        self.path = RemotePath.normalized(startPath)
    }

    // MARK: - Navigation

    /// Loads the start folder once.
    func start() {
        guard !started else { return }
        started = true
        load(path, action: "start")
    }

    /// Opens a row: navigates into folders and symlinks; files are ignored until Quick Look (milestone 6).
    func open(_ row: FileRow) {
        guard row.isNavigable else { return }
        Logger.ui.info("open path=\(row.file.path, privacy: .public)")
        navigate(to: row.file.path, action: "open")
    }

    /// The selected rows, in table order.
    var selectedRows: [FileRow] {
        rows.filter { selection.contains($0.id) }
    }

    /// Opens the single selected row (⌘↓ / Return).
    func openSelection() {
        guard selection.count == 1, let selected = selection.first, let row = rows.first(where: { $0.id == selected }) else { return }
        open(row)
    }

    /// - Parameter action: How the user navigated (`go`, `open`, `breadcrumb`, `up`); logged for profiling.
    func navigate(to newPath: String, action: String = "go") {
        let target = RemotePath.normalized(newPath)
        guard target != path else { return refresh() }
        backStack.append(path)
        forwardStack.removeAll()
        load(target, action: action)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        load(previous, action: "back")
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        load(next, action: "forward")
    }

    func goUp() {
        guard let parent = RemotePath.parent(of: path) else { return }
        navigate(to: parent, action: "up")
    }

    func refresh() {
        load(path, action: "refresh")
    }

    func setSelection(_ paths: Set<String>) {
        guard paths != selection else { return }
        selection = paths
        Logger.ui.info("selection count=\(paths.count)")
    }

    /// Stops the listing in flight; nothing this store started will write state afterwards.
    func cancel(reason: String) {
        Logger.ui.info("browser cancel reason=\(reason, privacy: .public) inFlight=\(self.loadTask != nil)")
        if loadTask != nil { Logger.ui.info("listing cancelled reason=\(reason, privacy: .public)") }
        loadTask?.cancel()
        loadTask = nil
        generation += 1
    }

    // MARK: - Loading

    private func load(_ target: String, action: String) {
        if loadTask != nil { cancel(reason: "navigate") }
        if target != path {
            // A refresh of the same folder keeps the selection; it is trimmed to what still exists later.
            selection = []
        }
        path = target
        generation += 1
        let token = generation
        loadTask = Task { [weak self] in await self?.performLoad(target, action: action, token: token) }
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == generation && !Task.isCancelled
    }

    private func performLoad(_ target: String, action: String, token: Int) async {
        let clock = ContinuousClock()
        let began = clock.now
        let cached = await cache.cached(serial: serial, path: target)
        guard isCurrent(token) else { return }

        if let cached {
            await show(cached, token: token, keepSelection: false)
            guard isCurrent(token) else { return }
            Logger.ui.info(
                "navigate action=\(action, privacy: .public) path=\(target, privacy: .public) source=cache entries=\(cached.count) ms=\(Self.milliseconds(clock.now - began))"
            )
        } else {
            files = []
            builtRows = []
            rows = []
            rowsVersion += 1
            phase = .loading
        }

        do {
            let fresh = try await listing.list(target)
            guard isCurrent(token) else { return }
            let changed = await cache.store(fresh, serial: serial, path: target)
            guard isCurrent(token) else { return }
            if cached != nil {
                Logger.ui.info("refresh path=\(target, privacy: .public) changed=\(changed)")
                if changed { await show(fresh, token: token, keepSelection: true) }
            } else {
                await show(fresh, token: token, keepSelection: false)
                Logger.ui.info(
                    "navigate action=\(action, privacy: .public) path=\(target, privacy: .public) source=device entries=\(fresh.count) ms=\(Self.milliseconds(clock.now - began))"
                )
            }
        } catch {
            guard isCurrent(token) else { return }
            // This load was not cancelled, so a CancellationError means the connection was closed under it
            // (e.g. another window disconnected the shared client). Treat it as a failure, never as silence.
            handle(error is CancellationError ? AdbError.connectionClosed : error, hadCache: cached != nil, path: target)
        }
        if isCurrent(token) { loadTask = nil }
    }

    private func handle(_ error: Error, hadCache: Bool, path target: String) {
        Logger.ui.error("listing failed path=\(target, privacy: .public): \(error.localizedDescription, privacy: .public)")
        switch error {
        case AdbError.permissionDenied:
            clearRows(phase: .denied)
        case AdbError.notFound, AdbError.notADirectory:
            Task { await cache.remove(serial: serial, path: target) }
            clearRows(phase: .notFound)
        default:
            // A cached listing stays visible when only the background refresh failed.
            if !hadCache { clearRows(phase: .failed(error.localizedDescription)) }
        }
    }

    private func clearRows(phase newPhase: Phase) {
        files = []
        builtRows = []
        rows = []
        rowsVersion += 1
        phase = newPhase
    }

    /// Sorts off the main thread, then publishes the rows if this load is still current.
    private func show(_ listing: [RemoteFile], token: Int, keepSelection: Bool) async {
        let sort = self.sort
        let showHidden = self.showHidden
        let pipeline = self.pipeline
        let (all, arranged) = await Task.detached(priority: .userInitiated) {
            let all = await pipeline.build(listing)
            return (all, await pipeline.arrange(all, sort, showHidden))
        }.value
        guard isCurrent(token) else { return }
        files = listing
        builtRows = all
        arrangeEpoch += 1 // drops any re-arrange still working on the previous builtRows
        rows = arranged
        rowsVersion += 1
        if keepSelection {
            let present = Set(arranged.map(\.id))
            selection = selection.intersection(present)
        }
        phase = listing.isEmpty ? .empty : .loaded
        if sort != self.sort || showHidden != self.showHidden {
            // The user changed the order while these rows were being built: arrange them again.
            rebuildRows()
        }
    }

    private func rebuildRows() {
        let all = builtRows
        let sort = self.sort
        let showHidden = self.showHidden
        let token = generation
        arrangeEpoch += 1
        let epoch = arrangeEpoch
        let began = ContinuousClock.now
        let pipeline = self.pipeline
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                await pipeline.arrange(all, sort, showHidden)
            }.value
            guard let self, token == self.generation, epoch == self.arrangeEpoch else { return }
            self.rows = built
            self.rowsVersion += 1
            self.selection = self.selection.intersection(Set(built.map(\.id)))
            Logger.ui.info("arrange rows=\(built.count) ms=\(Self.milliseconds(ContinuousClock.now - began))")
        }
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
