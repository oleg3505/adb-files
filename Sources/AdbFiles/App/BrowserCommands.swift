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
            Button("Internal Storage") { browser?.navigate(to: BrowserStore.startPath) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(browser == nil)
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
}
