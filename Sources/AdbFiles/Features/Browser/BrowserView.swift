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
    @State private var preview: PreviewController?
    @State private var presenter: QuickLookPanelPresenter?
    @State private var thumbnails: ThumbnailBinder?
    @AppStorage(RowSize.storageKey) private var rowSize: RowSize = .small

    var body: some View {
        Group {
            if let store {
                content(store)
                    .focusedSceneValue(\.browser, store)
                    .focusedSceneValue(\.preview, preview)
                    .navigationTitle(store.path == "/" ? device.displayName : (store.path as NSString).lastPathComponent)
                    .navigationSubtitle(device.displayName)
                    .toolbar { toolbar(store) }
                    .onChange(of: services.lastUpload) { _, event in
                        // A finished upload into the folder on screen shows up without ⌘R.
                        if let event, event.serial == store.serial, event.folder == store.path { store.refresh() }
                    }
                    .onChange(of: store.selection) { preview?.selectionChanged(store.selectedRows.map(\.file)) }
                    .onChange(of: store.path) { preview?.close() }
            } else {
                ProgressView()
            }
        }
        .task(id: device.serial) { await run(serial: device.serial) }
    }

    @ViewBuilder
    private func content(_ store: BrowserStore) -> some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                path: store.path, navigate: { store.navigate(to: $0, action: "breadcrumb") },
                draggingPaths: store.draggingPaths,
                canOperate: store.canOperate,
                moveRows: { paths, folder, copy in store.transfer(paths, into: folder, copy: copy) },
                uploadFiles: { urls, folder in upload(urls, into: folder, store: store) }
            )
            Divider()
            if store.phase == .loaded || store.phase == .empty {
                // An empty folder still shows the (empty) table, like Finder, so it accepts drops everywhere.
                FileTableView(
                    folderPath: store.path, rows: store.rows, rowsVersion: store.rowsVersion, selection: store.selection, sort: store.sort,
                    onSelect: store.setSelection, onOpen: store.open, onSort: { store.sort = $0 },
                    promise: { row in promise(for: row, serial: store.serial) },
                    onDropFiles: { urls, folder in upload(urls, into: folder?.file.path ?? store.path, store: store) },
                    editingPath: store.editingPath,
                    actions: tableActions(store),
                    preview: presenter,
                    rowSize: rowSize,
                    thumbnails: thumbnails
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
            if let name = preview?.loadingName {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading preview of “\(name)”…").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Cancel") { preview?.close() }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .accessibilityElement(children: .combine)
            }
            if let busy = store.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.busyText(busy)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .accessibilityElement(children: .combine)
            }
            TransferStatusBar(queue: services.transfers)
        }
        .confirmationDialog(
            Self.deleteTitle(store.pendingDeletion ?? []),
            isPresented: Binding(get: { store.pendingDeletion != nil }, set: { if !$0 { store.resolveDeletion(confirmed: false) } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { store.resolveDeletion(confirmed: true) }
            Button("Cancel", role: .cancel) { store.resolveDeletion(confirmed: false) }
        } message: {
            Text("This can’t be undone. Android has no Trash, so the items are removed from the device permanently.")
        }
        .alert(
            store.alert?.title ?? "",
            isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert?.message ?? "")
        }
    }

    private static func busyText(_ op: String) -> String {
        switch op {
        case "delete": "Deleting…"
        case "move": "Moving…"
        case "copy": "Copying on the device…"
        case "mkdir": "Creating folder…"
        default: "Renaming…"
        }
    }

    private static func deleteTitle(_ paths: [String]) -> String {
        paths.count == 1 ? "Delete “\((paths[0] as NSString).lastPathComponent)”?" : "Delete \(paths.count) items?"
    }

    private func tableActions(_ store: BrowserStore) -> FileTableActions {
        let start = services.startTransfers
        return FileTableActions(
            canOperate: store.canOperate,
            beginRename: { store.beginRename($0) },
            commitRename: { store.commitRename($0, to: $1) },
            cancelRename: { store.cancelRename() },
            moveRows: { paths, folder, copy in store.transfer(paths, into: folder, copy: copy) },
            menuItems: { clicked, selection in
                ContextMenu.items(clicked: clicked, selection: selection, store: store, startTransfers: start, preview: preview)
            },
            dragChanged: { store.draggingPaths = $0 },
            quickLook: { preview?.toggle(store.selectedRows.map(\.file)) },
            prefetch: { store.prefetch($0) }
        )
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
        services.startTransfers(TransferActions.uploadRequests(urls, serial: store.serial, to: remoteFolder))
        Logger.transfer.info("drop upload items=\(urls.count) folder=\(remoteFolder, privacy: .public)")
    }

    /// Owns the store for one device; runs until SwiftUI cancels the task.
    private func run(serial: String) async {
        let client = services.syncClient(for: serial)
        // Debugging aid: ADBFILES_START_PATH opens another folder first (documented in README).
        let startPath = ProcessInfo.processInfo.environment["ADBFILES_START_PATH"] ?? BrowserStore.startPath
        let newStore = BrowserStore(
            serial: serial, listing: client, cache: services.listingCache, startPath: startPath,
            operations: AdbFileOperations(serial: serial, client: client),
            prefetcher: services.prefetcher(for: serial)
        )
        let newPresenter = QuickLookPanelPresenter()
        let newPreview = PreviewController(
            cache: PreviewCache(serial: serial), downloader: InteractivePreviewDownloader(client: client), presenter: newPresenter,
            onFailure: { [weak newStore] alert in newStore?.alert = alert }
        )
        newPresenter.onClose = { [weak newPreview] in newPreview?.panelDidClose() }
        newPresenter.onToggle = { [weak newPreview] in newPreview?.close() }
        let service = services.thumbnails(for: serial)
        let binder = ThumbnailBinder { await service.thumbnail(for: $0) }
        thumbnails = binder
        presenter = newPresenter
        preview = newPreview
        store = newStore
        newStore.start()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        let gone = !isDeviceUsable(serial)
        newPreview.cancel()
        binder.unbindAll() // only this browser's requests: another window may show the same device
        newStore.cancel(reason: gone ? "device-gone" : "device-switch")
        if gone { await client.disconnect() }
    }
}

/// Lets menu commands act on the browser of the focused window.
struct FocusedBrowserKey: FocusedValueKey {
    typealias Value = BrowserStore
}

/// Lets the File menu's Quick Look act on the focused window's preview controller.
struct FocusedPreviewKey: FocusedValueKey {
    typealias Value = PreviewController
}

extension FocusedValues {
    var browser: BrowserStore? {
        get { self[FocusedBrowserKey.self] }
        set { self[FocusedBrowserKey.self] = newValue }
    }

    var preview: PreviewController? {
        get { self[FocusedPreviewKey.self] }
        set { self[FocusedPreviewKey.self] = newValue }
    }
}
