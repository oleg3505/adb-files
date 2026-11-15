import AdbKit
import Foundation
import Observation
import os

/// Shows local files in the Quick Look panel. `QuickLookPanelPresenter` in production, a fake in tests.
@MainActor
protocol PreviewPresenting: AnyObject {
    var isVisible: Bool { get }
    /// Shows `urls` (opening the panel if needed); `title` per item is the file name.
    func show(_ urls: [URL])
    func close()
}

/// Quick Look for one device's browser: Space toggles the panel for the selected files, which are first
/// downloaded to `PreviewCache` (reused while size and mtime match).
///
/// Every request carries a token. Selecting something else, closing the panel or leaving the device cancels
/// the current download; a cancelled or superseded request never shows an alert and never touches the panel.
@Observable
@MainActor
final class PreviewController {
    /// Name of the file being downloaded for the preview (drives the spinner), nil when idle.
    private(set) var loadingName: String?

    @ObservationIgnored private let cache: PreviewCache
    @ObservationIgnored private let downloader: any PreviewDownloading
    @ObservationIgnored private let presenter: any PreviewPresenting
    @ObservationIgnored private let onFailure: (OperationAlert) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = 0
    /// Paths of the current request (to ignore a selection change that changes nothing).
    @ObservationIgnored private var current: [String] = []
    /// Whether the panel should be up: set by Space, cleared by closing. Selection changes follow only then.
    @ObservationIgnored private(set) var isActive = false

    init(
        cache: PreviewCache, downloader: any PreviewDownloading, presenter: any PreviewPresenting,
        onFailure: @escaping (OperationAlert) -> Void
    ) {
        self.cache = cache
        self.downloader = downloader
        self.presenter = presenter
        self.onFailure = onFailure
    }

    /// Space / the context menu: opens the panel for `selection`, or closes it when it is up.
    func toggle(_ selection: [RemoteFile]) {
        if isActive || presenter.isVisible {
            close()
            return
        }
        let files = Self.previewable(selection)
        guard !files.isEmpty else { return }
        isActive = true
        Logger.ui.info("preview open count=\(files.count)")
        request(files)
    }

    /// The table selection changed: while the panel is up it follows (↑/↓ like Finder).
    func selectionChanged(_ selection: [RemoteFile]) {
        guard isActive else { return }
        let files = Self.previewable(selection)
        guard !files.isEmpty, files.map(\.path) != current else { return }
        request(files)
    }

    /// Closes the panel and drops any download in flight.
    func close() {
        let wasActive = isActive
        isActive = false
        cancelPending()
        if presenter.isVisible { presenter.close() }
        if wasActive { Logger.ui.info("preview close") }
    }

    /// The panel was closed by the user (Esc, its close button): forget the request.
    func panelDidClose() {
        guard isActive else { return }
        isActive = false
        cancelPending()
        Logger.ui.info("preview close")
    }

    /// The browser is going away (device gone or switched): stop quietly and let go of the panel.
    func cancel() {
        isActive = false
        cancelPending()
        presenter.close()
    }

    // MARK: - Requests

    /// Folders and links have no preview.
    static func previewable(_ files: [RemoteFile]) -> [RemoteFile] {
        files.filter { !$0.isDirectory && !$0.isSymlink && !$0.hasError }
    }

    private func cancelPending() {
        token += 1
        if task != nil, let name = loadingName {
            Logger.ui.info("preview cancelled path=\(name, privacy: .public)")
        }
        task?.cancel()
        task = nil
        loadingName = nil
        current = []
    }

    private func request(_ files: [RemoteFile]) {
        cancelPending()
        current = files.map(\.path)
        let myToken = token
        let missing = files.filter { cache.cachedURL(for: $0) == nil }
        if missing.isEmpty {
            for file in files { Logger.ui.info("preview ready path=\(file.path, privacy: .public) source=cache ms=0") }
            presenter.show(files.map { cache.url(for: $0) })
            return
        }
        loadingName = missing[0].name
        task = Task { [weak self] in
            await self?.download(missing, all: files, token: myToken)
        }
    }

    private func download(_ missing: [RemoteFile], all files: [RemoteFile], token myToken: Int) async {
        let clock = ContinuousClock()
        for file in missing {
            let started: ContinuousClock.Instant = clock.now
            do {
                try cache.prepare(for: file)
                try await downloader.download(file, to: cache.url(for: file))
                try Task.checkCancellation()
            } catch {
                failed(file, error: error, token: myToken)
                return
            }
            guard token == myToken else { return } // superseded: drop the result
            let ms: Int = Self.milliseconds(clock.now - started)
            Logger.ui.info("preview ready path=\(file.path, privacy: .public) source=device ms=\(ms)")
        }
        finished(files, token: myToken)
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func finished(_ files: [RemoteFile], token myToken: Int) {
        guard token == myToken, isActive else { return }
        task = nil
        loadingName = nil
        presenter.show(files.map { cache.url(for: $0) })
    }

    private func failed(_ file: RemoteFile, error: Error, token myToken: Int) {
        // Cancelled or superseded: nothing to report.
        guard token == myToken, !(error is CancellationError), !Task.isCancelled else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Logger.ui.error("preview failed path=\(file.path, privacy: .public) reason=\(message, privacy: .public)")
        task = nil
        loadingName = nil
        isActive = false
        current = []
        if presenter.isVisible { presenter.close() }
        onFailure(OperationAlert(title: "Couldn’t Load the Preview", message: "“\(file.name)”: \(message)"))
    }
}
