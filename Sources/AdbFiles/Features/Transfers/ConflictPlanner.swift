import AdbKit
import Foundation
import os

/// One name clash shown to the user.
struct ConflictQuestion: Equatable, Sendable {
    let name: String
    let isFolder: Bool
    /// Display name of the destination folder ("Download", "Desktop").
    let destination: String
    /// Clashes of the same kind (files or folders) still to decide, this one included.
    let remaining: Int
    let direction: TransferDirection
}

/// The user's answer: a choice (nil = stop, enqueue nothing) and whether it applies to the remaining clashes of the
/// same kind.
struct ConflictAnswer: Equatable, Sendable {
    let choice: ConflictChoice?
    var applyToAll = false

    static let stop = ConflictAnswer(choice: nil)
}

/// Checks transfer requests for names that already exist at their destination and asks what to do, **before**
/// anything is enqueued.
///
/// Names are looked up once per destination folder, off the main actor. Folders are offered Keep Both / Skip
/// only (replacing a whole folder is too risky without a Trash). If a lookup fails, its requests go ahead with
/// keep-both naming — the queue never overwrites unless the user chose Replace. A clash that appears after the
/// check is also resolved with keep-both by the queue.
@MainActor
final class ConflictPlanner {
    /// Names present in a request's destination folder (remote listing or local directory).
    typealias Lookup = @Sendable (TransferRequest) async throws -> Set<String>
    typealias Ask = @MainActor (ConflictQuestion) async -> ConflictAnswer

    private let lookup: Lookup
    private let ask: Ask

    init(lookup: @escaping Lookup, ask: @escaping Ask) {
        self.lookup = lookup
        self.ask = ask
    }

    /// The requests to enqueue: clashing ones carry the chosen `conflict`; skipped ones are left out; empty when
    /// the user stopped.
    func plan(_ requests: [TransferRequest]) async -> [TransferRequest] {
        var existing: [String: Set<String>] = [:]
        for request in requests where request.fixedName == nil {
            let key = Self.folderKey(request)
            guard existing[key] == nil else { continue }
            do {
                let names = try await lookup(request)
                existing[key] = Set(names.map { Self.normalized($0, request) })
            } catch {
                Logger.transfer.error("conflict check failed folder=\(request.targetFolder, privacy: .public): \(error.localizedDescription, privacy: .public)")
                existing[key] = []
            }
        }
        func clashes(_ request: TransferRequest) -> Bool {
            request.fixedName == nil && existing[Self.folderKey(request)]?.contains(Self.normalized(request.name, request)) == true
        }

        var remaining = (files: requests.filter { clashes($0) && !$0.isFolder }.count,
                         folders: requests.filter { clashes($0) && $0.isFolder }.count)
        var sticky: (files: ConflictChoice?, folders: ConflictChoice?) = (nil, nil)
        var planned: [TransferRequest] = []
        for var request in requests {
            guard clashes(request) else {
                planned.append(request)
                continue
            }
            let isFolder = request.isFolder
            var choice = isFolder ? sticky.folders : sticky.files
            if choice == nil {
                let question = ConflictQuestion(
                    name: request.name, isFolder: isFolder, destination: Self.displayName(request.targetFolder),
                    remaining: isFolder ? remaining.folders : remaining.files, direction: request.direction
                )
                let answer = await ask(question)
                Logger.transfer.info(
                    "conflict ask name=\(request.name, privacy: .public) choice=\(answer.choice?.rawValue ?? "stop", privacy: .public) all=\(answer.applyToAll)"
                )
                guard var picked = answer.choice else { return [] }
                if isFolder, picked == .replace { picked = .keepBoth } // never replace a folder
                choice = picked
                if answer.applyToAll {
                    if isFolder { sticky.folders = picked } else { sticky.files = picked }
                }
            }
            if isFolder { remaining.folders -= 1 } else { remaining.files -= 1 }
            switch choice {
            case .skip:
                continue
            case .replace, .keepBoth, nil:
                request.conflict = choice ?? .keepBoth
                planned.append(request)
            }
        }
        return planned
    }

    private static func folderKey(_ request: TransferRequest) -> String {
        "\(request.direction)|\(request.serial)|\(request.targetFolder)"
    }

    /// Android's shared storage is case-insensitive, so remote names are compared without case.
    private static func normalized(_ name: String, _ request: TransferRequest) -> String {
        request.direction == .upload ? name.lowercased() : name
    }

    private static func displayName(_ folder: String) -> String {
        let name = (folder as NSString).lastPathComponent
        return name.isEmpty ? folder : name
    }
}

extension ConflictPlanner {
    /// Production lookup: lists the remote folder for uploads, reads the Mac folder for downloads; both run off
    /// the main actor (this closure is not isolated).
    nonisolated static func liveLookup(client: @escaping @Sendable (String) async -> AdbSyncClient) -> Lookup {
        { request in
            switch request.direction {
            case .upload:
                let files = try await client(request.serial).list(request.targetFolder)
                return Set(files.map(\.name))
            case .download:
                return Set(try FileManager.default.contentsOfDirectory(atPath: request.targetFolder))
            }
        }
    }
}
