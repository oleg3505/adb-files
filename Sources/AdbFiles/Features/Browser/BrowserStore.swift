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

    /// Name of the operation running now (one at a time); nil when idle.
    private(set) var busy: String? {
        didSet {
            if let busy { Logger.ui.info("busy begin op=\(busy, privacy: .public)") }
            else if let oldValue { Logger.ui.info("busy end op=\(oldValue, privacy: .public)") }
        }
    }
    /// An operation error to show.
    var alert: OperationAlert?
    /// The row whose name is being edited inline.
    private(set) var editingPath: String?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { RemotePath.parent(of: path) != nil }

    @ObservationIgnored private let listing: any DirectoryListing
    @ObservationIgnored private let cache: ListingCache
    @ObservationIgnored private let operations: (any FileOperating)?
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
    @ObservationIgnored private let prefetcher: Prefetcher

    /// - Parameter prefetchSleep: Waits out the prefetch delay; injectable so tests decide when it elapses.
    init(
        serial: String, listing: any DirectoryListing, cache: ListingCache, startPath: String = BrowserStore.startPath,
        pipeline: RowPipeline = RowPipeline(), operations: (any FileOperating)? = nil,
        prefetchSleep: Prefetcher.Sleep? = nil
    ) {
        self.serial = serial
        self.listing = listing
        self.cache = cache
        self.operations = operations
        self.pipeline = pipeline
        self.path = RemotePath.normalized(startPath)
        if let prefetchSleep {
            prefetcher = Prefetcher(serial: serial, listing: listing, cache: cache, sleep: prefetchSleep)
        } else {
            prefetcher = Prefetcher(serial: serial, listing: listing, cache: cache)
        }
    }

    /// The pointer rests on, or the selection is, the folder at `path` (nil: none): prefetch it after 150 ms.
    func prefetch(_ path: String?) {
        prefetcher.request(path.map(RemotePath.normalized))
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
        prefetcher.cancel()
    }

    // MARK: - File operations

    /// Whether an operation may start now.
    var canOperate: Bool { busy == nil && operations != nil }

    func beginRename(_ path: String) {
        guard canOperate, editingPath == nil, rows.contains(where: { $0.id == path }) else { return }
        editingPath = path
        Logger.ui.info("rename begin path=\(path, privacy: .public)")
    }

    func cancelRename() {
        guard let path = editingPath else { return }
        editingPath = nil
        Logger.ui.info("rename cancel path=\(path, privacy: .public)")
    }

    /// Commits an inline rename. Invalid names and clashes show an alert; the same name does nothing.
    func commitRename(_ path: String, to newName: String) {
        editingPath = nil
        Logger.ui.info("rename commit path=\(path, privacy: .public)")
        let oldName = (path as NSString).lastPathComponent
        guard newName != oldName else { return }
        if let problem = NameValidation.problem(with: newName) {
            return showAlert(op: "rename", title: "Can’t rename “\(oldName)”", message: problem)
        }
        let clash = rows.contains { $0.name != oldName && $0.name.lowercased() == newName.lowercased() }
        if clash {
            return showAlert(op: "rename", title: "Can’t rename “\(oldName)”", message: "An item named “\(newName)” already exists here.")
        }
        guard let operations else { return }
        run("rename", affected: [folder(of: path)]) {
            do {
                let newPath = try await operations.rename(path, to: newName)
                return OperationOutcome(select: newPath)
            } catch {
                return OperationOutcome(failures: [FailedItem(name: oldName, message: Self.message(error))])
            }
        }
    }

    /// Creates `untitled folder` (or the next free number, case-insensitively) and starts renaming it.
    func newFolder() {
        guard let operations, editingPath == nil else { return }
        let name = Self.uniqueName("untitled folder", taken: Set(rows.map { $0.name.lowercased() }))
        let target = RemotePath.join(path, name)
        run("mkdir", affected: [path]) {
            do {
                try await operations.makeDirectory(target)
                return OperationOutcome(select: target, edit: target)
            } catch {
                return OperationOutcome(failures: [FailedItem(name: name, message: Self.message(error))])
            }
        }
    }

    /// Rows currently being dragged from this browser's table (for drops on the path bar).
    var draggingPaths: [String] = []

    /// Paths waiting for the delete confirmation dialog.
    private(set) var pendingDeletion: [String]?

    /// Asks for confirmation before deleting (⌘⌫, context menu).
    func requestDelete(_ paths: [String]) {
        guard canOperate, editingPath == nil, !paths.isEmpty else { return }
        pendingDeletion = paths
    }

    func resolveDeletion(confirmed: Bool) {
        guard let paths = pendingDeletion else { return }
        pendingDeletion = nil
        Logger.ui.info("confirm delete count=\(paths.count) result=\(confirmed ? "confirm" : "cancel", privacy: .public)")
        if confirmed { delete(paths) }
    }

    /// Deletes the given paths permanently (the confirmation is the caller's job).
    func delete(_ paths: [String]) {
        guard let operations, !paths.isEmpty else { return }
        run("delete", affected: Set(paths.map(folder(of:))), count: paths.count) {
            let results = await operations.delete(paths)
            return OperationOutcome(failures: Self.failures(results))
        }
    }

    /// Moves (or copies) paths into a folder on the same device.
    func transfer(_ paths: [String], into folder: String, copy: Bool) {
        guard let operations, !paths.isEmpty else { return }
        let destination = RemotePath.normalized(folder)
        run(copy ? "copy" : "move", affected: Set(paths.map(folder(of:)) + [destination]), count: paths.count) {
            let results = copy ? await operations.copy(paths, into: destination) : await operations.move(paths, into: destination)
            return OperationOutcome(failures: Self.failures(results))
        }
    }

    /// The remote paths, one per line (Copy Path).
    func pathsText(_ paths: [String]) -> String {
        Logger.ui.info("copy path count=\(paths.count)")
        return paths.joined(separator: "\n")
    }

    struct FailedItem: Sendable, Equatable {
        let name: String
        let message: String
    }

    struct OperationOutcome: Sendable {
        var failures: [FailedItem] = []
        var select: String?
        var edit: String?
    }

    private func folder(of item: String) -> String {
        RemotePath.parent(of: item) ?? "/"
    }

    /// Runs one operation at a time. The task is not tied to navigation and is never cancelled by it: whatever
    /// happens, every affected folder is invalidated and failures are shown; only selection and inline editing
    /// need the user to still be in the folder where the operation started.
    private func run(_ op: String, affected: Set<String>, count: Int = 1, _ work: @escaping @Sendable () async -> OperationOutcome) {
        guard canOperate else {
            Logger.ui.info("op \(op, privacy: .public) refused busy=\(self.busy ?? "-", privacy: .public)")
            return
        }
        busy = op
        let folderAtStart = path
        let started = ContinuousClock.now
        let cache = self.cache
        let serial = self.serial
        Task {
            let outcome = await work()
            // Also forget listings below them (a renamed/moved/deleted folder's subfolders are stale too).
            for folder in affected { await cache.removeTree(serial: serial, path: RemotePath.normalized(folder)) }
            self.finishOperation(op, count: count, outcome: outcome, affected: affected, folderAtStart: folderAtStart, started: started)
        }
    }

    private func finishOperation(
        _ op: String, count: Int, outcome: OperationOutcome, affected: Set<String>, folderAtStart: String, started: ContinuousClock.Instant
    ) {
        busy = nil
        Logger.ui.info(
            "op \(op, privacy: .public) count=\(count) ok=\(count - outcome.failures.count) fail=\(outcome.failures.count) ms=\(Self.milliseconds(ContinuousClock.now - started))"
        )
        if !outcome.failures.isEmpty {
            let lines = outcome.failures.map { "“\($0.name)”: \($0.message)" }.joined(separator: "\n")
            showAlert(op: op, title: Self.failureTitle(op, count: outcome.failures.count), message: lines)
        }
        if path == folderAtStart {
            if let select = outcome.select { selection = [select] }
            if let edit = outcome.edit { editingPath = edit }
        }
        if affected.contains(path) { refresh() }
    }

    private func showAlert(op: String, title: String, message: String) {
        alert = OperationAlert(title: title, message: message)
        Logger.ui.info("alert op=\(op, privacy: .public) reason=\(message, privacy: .public)")
    }

    private nonisolated static func failures<T>(_ results: [String: Result<T, AdbError>]) -> [FailedItem] {
        results.compactMap { path, result -> FailedItem? in
            guard case .failure(let error) = result else { return nil }
            return FailedItem(name: (path as NSString).lastPathComponent, message: message(error))
        }.sorted { $0.name < $1.name }
    }

    private nonisolated static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func failureTitle(_ op: String, count: Int) -> String {
        let noun = count == 1 ? "1 item" : "\(count) items"
        switch op {
        case "delete": return "Couldn’t delete \(noun)"
        case "move": return "Couldn’t move \(noun)"
        case "copy": return "Couldn’t copy \(noun)"
        case "mkdir": return "Couldn’t create the folder"
        default: return "Couldn’t rename"
        }
    }

    /// `base`, `base 2`, `base 3`, … — the first whose lowercased form is not in `taken`.
    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: - Loading

    private func load(_ target: String, action: String) {
        if loadTask != nil { cancel(reason: "navigate") }
        // Reloading the folder on screen (⌘R, after an operation) keeps the current rows visible until the new
        // listing arrives, instead of flashing a spinner.
        let keepVisible = target == path && (phase == .loaded || phase == .empty)
        if target != path {
            // A refresh of the same folder keeps the selection; it is trimmed to what still exists later.
            selection = []
        }
        path = target
        generation += 1
        let token = generation
        loadTask = Task { [weak self] in await self?.performLoad(target, action: action, token: token, keepVisible: keepVisible) }
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == generation && !Task.isCancelled
    }

    private func performLoad(_ target: String, action: String, token: Int, keepVisible: Bool = false) async {
        let clock = ContinuousClock()
        let began = clock.now
        // Reuse a prefetch of this folder that is still running; any other prefetch is cancelled so it can't hold
        // the listing connection.
        let prefetched = prefetcher.take(target)
        let cached = await cache.cached(serial: serial, path: target)
        guard isCurrent(token) else { return }

        if let cached {
            await show(cached, token: token, keepSelection: false)
            guard isCurrent(token) else { return }
            Logger.ui.info(
                "navigate action=\(action, privacy: .public) path=\(target, privacy: .public) source=cache entries=\(cached.count) ms=\(Self.milliseconds(clock.now - began))"
            )
            if !keepVisible, prefetcher.isFresh(target) {
                // Listed by the prefetch moments ago: a second listing would only repeat it.
                if isCurrent(token) { loadTask = nil }
                return
            }
        } else if !keepVisible {
            files = []
            builtRows = []
            rows = []
            rowsVersion += 1
            phase = .loading
        }

        do {
            let fresh: [RemoteFile]
            if let prefetched,
               let files = await withTaskCancellationHandler(operation: { await prefetched.value }, onCancel: { prefetched.cancel() }) {
                fresh = files
                Logger.ui.info("prefetch reused path=\(target, privacy: .public)")
            } else {
                fresh = try await listing.list(target)
            }
            guard isCurrent(token) else { return }
            let changed = await cache.store(fresh, serial: serial, path: target)
            guard isCurrent(token) else { return }
            if cached != nil {
                Logger.ui.info("refresh path=\(target, privacy: .public) changed=\(changed)")
                if changed { await show(fresh, token: token, keepSelection: true) }
            } else {
                await show(fresh, token: token, keepSelection: keepVisible)
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
