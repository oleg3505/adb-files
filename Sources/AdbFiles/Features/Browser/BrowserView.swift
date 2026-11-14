import AdbKit
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
            if store.phase == .loaded {
                FileTableView(
                    folderPath: store.path, rows: store.rows, rowsVersion: store.rowsVersion, selection: store.selection, sort: store.sort,
                    onSelect: store.setSelection, onOpen: store.open, onSort: { store.sort = $0 }
                )
            } else {
                BrowserStateView(phase: store.phase, retry: store.refresh)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
