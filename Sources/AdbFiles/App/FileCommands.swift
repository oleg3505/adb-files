import SwiftUI

/// File menu: New Folder (⌘⇧N), Rename, Delete (⌘⌫), Copy Path (⌥⌘C), acting on the focused browser.
struct FileCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("New Folder") { browser?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!(browser?.canOperate ?? false))
            Button("Rename") {
                if let browser, let path = browser.selection.first { browser.beginRename(path) }
            }
            .disabled(!(browser?.canOperate ?? false) || browser?.selection.count != 1)
            Button("Delete…") {
                if let browser { browser.requestDelete(browser.selectedRows.map(\.id)) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            // Disabled while renaming, so ⌘⌫ edits the name instead of deleting the row.
            .disabled(!(browser?.canOperate ?? false) || (browser?.selection.isEmpty ?? true) || browser?.editingPath != nil)
            Button("Copy Path") {
                if let browser {
                    let paths = browser.selection.isEmpty ? [browser.path] : browser.selectedRows.map(\.id)
                    ContextMenu.copyPaths(paths, store: browser)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(browser == nil)
        }
    }
}
