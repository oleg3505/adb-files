import AppKit

/// The file list's context menu: on rows (Open, Quick Look, Download To…, Rename, Copy Path, Delete) or on the
/// background (New Folder, Copy Path of the folder).
@MainActor
enum ContextMenu {
    static func items(clicked: FileRow?, selection: [FileRow], store: BrowserStore, queue: TransferQueue) -> [NSMenuItem] {
        let canOperate = store.canOperate && store.editingPath == nil
        guard clicked != nil, !selection.isEmpty else {
            return [
                ClosureMenuItem("New Folder", enabled: canOperate) { store.newFolder() },
                .separator(),
                ClosureMenuItem("Copy Path") { copyPaths([store.path], store: store) },
            ]
        }
        let paths = selection.map(\.id)
        let single = selection.count == 1 ? selection[0] : nil
        return [
            ClosureMenuItem("Open", enabled: single?.isNavigable == true) { if let single { store.open(single) } },
            ClosureMenuItem("Quick Look", enabled: false) {}, // milestone 6
            .separator(),
            ClosureMenuItem("Download To…") { TransferActions.downloadSelection(of: store, queue: queue) },
            .separator(),
            ClosureMenuItem("Rename", enabled: canOperate && single != nil) { if let single { store.beginRename(single.id) } },
            ClosureMenuItem("Copy Path") { copyPaths(paths, store: store) },
            .separator(),
            ClosureMenuItem(selection.count == 1 ? "Delete…" : "Delete \(selection.count) Items…", enabled: canOperate) {
                store.requestDelete(paths)
            },
            .separator(),
            ClosureMenuItem("New Folder", enabled: canOperate) { store.newFolder() },
        ]
    }

    static func copyPaths(_ paths: [String], store: BrowserStore) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.pathsText(paths), forType: .string)
    }
}
