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
    private let askConflict: @Sendable (ConflictQuestion) async -> ConflictAnswer
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(
        file: RemoteFile, serial: String,
        enqueue: @escaping @Sendable (TransferRequest, @escaping @Sendable (TransferItem.State) -> Void) -> Void,
        askConflict: @escaping @Sendable (ConflictQuestion) async -> ConflictAnswer = { await ConflictPrompt.ask($0) }
    ) {
        self.file = file
        self.serial = serial
        self.enqueue = enqueue
        self.askConflict = askConflict
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
        let done = CompletionBox(completionHandler)
        let folder = url.deletingLastPathComponent()
        // Finder renames silently ("name 2.ext") when the name is taken; ask like an upload would.
        var existingIsFolder: ObjCBool = false
        let clash = url.lastPathComponent != file.name
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent(file.name).path, isDirectory: &existingIsFolder)
        guard clash else {
            start(name: url.lastPathComponent, in: folder, conflict: .keepBoth, done: done)
            return
        }
        // A folder on either side: Keep Both / Skip only (Replace would delete or nest a folder).
        let question = ConflictQuestion(
            name: file.name, isFolder: file.isDirectory || existingIsFolder.boolValue, destination: folder.lastPathComponent,
            remaining: 1, direction: .download
        )
        let ask = askConflict
        Task {
            let answer = await ask(question)
            Logger.transfer.info(
                "conflict ask name=\(question.name, privacy: .public) choice=\(answer.choice?.rawValue ?? "stop", privacy: .public) via=promise"
            )
            switch answer.choice {
            case .replace where !question.isFolder:
                self.start(name: question.name, in: folder, conflict: .replace, done: done)
            case .keepBoth, .replace:
                self.start(name: url.lastPathComponent, in: folder, conflict: .keepBoth, done: done)
            case .skip, nil:
                done.call(CocoaError(.userCancelled))
            }
        }
    }

    /// Downloads into `folder/name` (Finder's chosen name, or the original one when replacing).
    private func start(name fixedName: String, in folder: URL, conflict: ConflictChoice, done: CompletionBox) {
        var request = TransferRequest(
            direction: .download, serial: serial, sourcePath: file.path, isFolder: file.isDirectory,
            targetFolder: folder.path, size: file.size, modificationDate: file.modificationDate, fixedName: fixedName
        )
        request.conflict = conflict
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
