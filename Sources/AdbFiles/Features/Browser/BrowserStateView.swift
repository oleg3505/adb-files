import SwiftUI

/// Non-table states of the browser: loading, empty folder, permission denied, not found, failure.
struct BrowserStateView: View {
    let phase: BrowserStore.Phase
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .loading:
            ProgressView("Loading…")
        case .loaded:
            EmptyView()
        case .empty:
            ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Drag files here to copy them to the device."))
        case .denied:
            ContentUnavailableView(
                "Permission Denied", systemImage: "lock",
                description: Text("Android does not allow ADB to read this folder.")
            )
        case .notFound:
            ContentUnavailableView("Folder Not Found", systemImage: "questionmark.folder", description: Text("It may have been moved or deleted."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retry)
            }
        }
    }
}
