import AdbKit
import AppKit
import os
import SwiftUI

/// File browser for one device: breadcrumbs, table or state view, toolbar.
///
/// The store lives for as long as this view shows the same device. When the device goes away (the view
/// disappears or the serial changes) the listing is cancelled; if the device is gone, its sync
/// connection is closed too.
struct BrowserView: View {
    let device: Device
    /// Whether the device is still connected and usable; checked when the view is torn down.
    let isDeviceUsable: (String) -> Bool

    @Environment(AppServices.self) private var services
    @State private var store: BrowserStore?

    var body: some View {
        Group {
            if let store {
                content(store)
                    .focusedSceneValue(\.browser, store)
                    .navigationTitle(store.path == "/" ? device.displayName : (store.path as NSString).lastPathComponent)
                    .navigationSubtitle(device.displayName)
                    .toolbar { toolbar(store) }
                    .onChange(of: services.lastUpload) { _, event in
                        // A finished upload into the folder on screen shows up without ⌘R.
                        if let event, event.serial == store.serial, event.folder == store.path { store.refresh() }
                    }
            } else {
                ProgressView()
            }
        }
        .task(id: device.serial) { await run(serial: device.serial) }
    }

    @ViewBuilder
    private func content(_ store: BrowserStore) -> some View {
        VStack(spacing: 0) {
            BreadcrumbBar(path: store.path) { store.navigate(to: $0, action: "breadcrumb") }
            Divider()
            if store.phase == .loaded || store.phase == .empty {
                // An empty folder still shows the (empty) table, like Finder, so it accepts drops everywhere.
                FileTableView(
                    folderPath: store.path, rows: store.rows, rowsVersion: store.rowsVersion, selection: store.selection, sort: store.sort,
                    onSelect: store.setSelection, onOpen: store.open, onSort: { store.sort = $0 },
                    promise: { row in promise(for: row, serial: store.serial) },
                    onDropFiles: { urls, folder in upload(urls, into: folder?.file.path ?? store.path, store: store) }
                )
                .overlay {
                    if store.phase == .empty {
                        BrowserStateView(phase: .empty, retry: store.refresh)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                BrowserStateView(phase: store.phase, retry: store.refresh)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            TransferStatusBar(queue: services.transfers)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ store: BrowserStore) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { store.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!store.canGoBack)
                .help("Back (⌘[)")
            Button { store.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!store.canGoForward)
                .help("Forward (⌘])")
        }
        ToolbarItem(placement: .primaryAction) {
            TransfersButton(queue: services.transfers)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.goUp() } label: { Label("Enclosing Folder", systemImage: "arrow.up") }
                .disabled(!store.canGoUp)
                .help("Enclosing Folder (⌘↑)")
            Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh (⌘R)")
            Toggle(isOn: Binding(get: { store.showHidden }, set: { store.showHidden = $0 })) {
                Label("Hidden Files", systemImage: store.showHidden ? "eye" : "eye.slash")
            }
            .help("Show Hidden Files (⌘⇧.)")
        }
    }

    private func promise(for row: FileRow, serial: String) -> NSFilePromiseProvider? {
        let queue = services.transfers
        let delegate = FilePromiseDelegate(file: row.file, serial: serial) { request, completion in
            Task { @MainActor in queue.enqueue(request) { completion($0) } }
        }
        return delegate.makeProvider()
    }

    private func upload(_ urls: [URL], into remoteFolder: String, store: BrowserStore) {
        services.transfers.enqueue(TransferActions.uploadRequests(urls, serial: store.serial, to: remoteFolder))
        Logger.transfer.info("drop upload items=\(urls.count) folder=\(remoteFolder, privacy: .public)")
    }

    /// Owns the store for one device; runs until SwiftUI cancels the task.
    private func run(serial: String) async {
        let client = services.syncClient(for: serial)
        // Debugging aid: ADBFILES_START_PATH opens another folder first (documented in README).
        let startPath = ProcessInfo.processInfo.environment["ADBFILES_START_PATH"] ?? BrowserStore.startPath
        let newStore = BrowserStore(serial: serial, listing: client, cache: services.listingCache, startPath: startPath)
        store = newStore
        newStore.start()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        let gone = !isDeviceUsable(serial)
        newStore.cancel(reason: gone ? "device-gone" : "device-switch")
        if gone { await client.disconnect() }
    }
}

/// Lets menu commands act on the browser of the focused window.
struct FocusedBrowserKey: FocusedValueKey {
    typealias Value = BrowserStore
}

extension FocusedValues {
    var browser: BrowserStore? {
        get { self[FocusedBrowserKey.self] }
        set { self[FocusedBrowserKey.self] = newValue }
    }
}
