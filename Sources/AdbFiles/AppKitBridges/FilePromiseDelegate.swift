import AdbKit
import AppKit
import os
import UniformTypeIdentifiers

/// Supplies one remote file or folder to Finder as a file promise: nothing is copied until the drop.
///
/// AppKit calls these methods on `operationQueue`, a background queue. The download is enqueued on the main
/// actor, and Finder's completion handler is called when the transfer ends.
final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    private let file: RemoteFile
    private let serial: String
    private let enqueue: @Sendable (TransferRequest, @escaping @Sendable (TransferItem.State) -> Void) -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(
        file: RemoteFile, serial: String,
        enqueue: @escaping @Sendable (TransferRequest, @escaping @Sendable (TransferItem.State) -> Void) -> Void
    ) {
        self.file = file
        self.serial = serial
        self.enqueue = enqueue
    }

    /// A provider for this file, retaining its delegate (NSFilePromiseProvider holds the delegate weakly).
    func makeProvider() -> NSFilePromiseProvider {
        let type = file.isDirectory ? UTType.folder : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = self
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        file.name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
    ) {
        Logger.transfer.info("promise write url=\(url.path, privacy: .public)")
        let request = TransferRequest(
            direction: .download, serial: serial, sourcePath: file.path, isFolder: file.isDirectory,
            targetFolder: url.deletingLastPathComponent().path, size: file.size, modificationDate: file.modificationDate
        )
        let done = CompletionBox(completionHandler)
        let name = file.name
        // Finder waits for the completion handler, which runs when the transfer ends.
        enqueue(request) { state in
            if case .done = state {
                done.call(nil)
            } else {
                done.call(AdbError.localIOError("The transfer of “\(name)” did not complete."))
            }
        }
    }
}

/// Carries Finder's non-Sendable completion handler to whichever thread finishes the transfer.
private final class CompletionBox: @unchecked Sendable {
    private let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func call(_ error: Error?) { handler(error) }
}
