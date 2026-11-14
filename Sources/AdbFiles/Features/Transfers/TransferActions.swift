import AdbKit
import AppKit
import os

/// Builds transfer requests from browser selections, Finder drops and open panels.
@MainActor
enum TransferActions {
    /// Requests that download `rows` into a Mac folder. Symlinks are skipped (their target is unknown).
    static func downloadRequests(_ rows: [FileRow], serial: String, to folder: URL) -> [TransferRequest] {
        rows.filter { !$0.file.isSymlink }.map { row in
            TransferRequest(
                direction: .download, serial: serial, sourcePath: row.file.path, isFolder: row.file.isDirectory,
                targetFolder: folder.path, size: row.file.size, modificationDate: row.file.modificationDate
            )
        }
    }

    /// Requests that upload Finder items into a remote folder.
    static func uploadRequests(_ urls: [URL], serial: String, to remoteFolder: String) -> [TransferRequest] {
        urls.map { url in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return TransferRequest(
                direction: .upload, serial: serial, sourcePath: url.path, isFolder: isFolder,
                targetFolder: RemotePath.normalized(remoteFolder)
            )
        }
    }

    /// "Download To…": asks for a Mac folder, then downloads the browser's selection there.
    static func downloadSelection(of browser: BrowserStore, queue: TransferQueue) {
        let rows = browser.selectedRows
        guard !rows.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        panel.message = rows.count == 1 ? "Choose where to save “\(rows[0].name)”." : "Choose where to save \(rows.count) items."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        queue.enqueue(downloadRequests(rows, serial: browser.serial, to: folder))
        Logger.transfer.info("download to folder items=\(rows.count)")
    }

    /// "Upload…": asks for Mac files/folders, then uploads them into the browser's current folder.
    static func uploadInto(_ browser: BrowserStore, queue: TransferQueue) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to copy to “\(browser.path)”."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        queue.enqueue(uploadRequests(panel.urls, serial: browser.serial, to: browser.path))
        Logger.transfer.info("upload items=\(panel.urls.count)")
    }
}
