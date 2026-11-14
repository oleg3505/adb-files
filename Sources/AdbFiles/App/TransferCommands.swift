import SwiftUI

/// File menu items for transfers, acting on the focused window's browser.
struct TransferCommands: Commands {
    let services: AppServices
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Download To…") {
                if let browser { TransferActions.downloadSelection(of: browser, queue: services.transfers) }
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(browser?.selection.isEmpty ?? true)
            Button("Upload…") {
                if let browser { TransferActions.uploadInto(browser, queue: services.transfers) }
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(browser == nil)
        }
    }
}
