import SwiftUI

/// Go menu and View items with Finder's shortcuts, acting on the focused window's browser.
struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(browser?.canGoBack ?? false))
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(browser?.canGoForward ?? false))
            Button("Enclosing Folder") { browser?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!(browser?.canGoUp ?? false))
            Button("Open") { browser?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(browser?.selection.count != 1)
            Divider()
            ForEach(Bookmark.all) { bookmark in
                Button(bookmark.name) { browser?.navigate(to: bookmark.path, action: "bookmark") }
                    .keyboardShortcut(Self.shortcut(for: bookmark))
                    .disabled(browser == nil)
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { browser?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(browser == nil)
            Button((browser?.showHidden ?? false) ? "Hide Hidden Files" : "Show Hidden Files") {
                browser?.showHidden.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(browser == nil)
            Divider()
        }
    }

    /// Finder-like shortcuts where Finder has an equivalent (⇧⌘I was already Internal Storage).
    private static func shortcut(for bookmark: Bookmark) -> KeyboardShortcut? {
        switch bookmark.path {
        case "/sdcard": KeyboardShortcut("i", modifiers: [.command, .shift])
        case "/sdcard/Download": KeyboardShortcut("l", modifiers: [.command, .option])
        case "/sdcard/Documents": KeyboardShortcut("o", modifiers: [.command, .shift])
        default: nil
        }
    }
}
