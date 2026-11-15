import AdbKit
import AppKit
import Foundation
import os
import Testing
@testable import AdbFiles

/// Drag to Finder: Finder renames a clashing file silently, so the promise delegate asks itself.
@Suite struct FilePromiseConflictTests {
    private final class Recorder: Sendable {
        let requests = OSAllocatedUnfairLock(initialState: [TransferRequest]())
        let questions = OSAllocatedUnfairLock(initialState: [ConflictQuestion]())
        let completion = OSAllocatedUnfairLock(initialState: [String]())
    }

    private func run(existing: [String], finderName: String, answer: ConflictAnswer) async throws -> Recorder {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-promise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in existing { try Data("old".utf8).write(to: folder.appendingPathComponent(name)) }
        let recorder = Recorder()
        let file = RemoteFile(name: "a.txt", path: "/sdcard/Download/a.txt", mode: 0o100660, size: 3, modificationDate: nil)
        let delegate = FilePromiseDelegate(
            file: file, serial: "S",
            enqueue: { request, done in
                recorder.requests.withLock { $0.append(request) }
                done(.done(copied: 1, skipped: 0))
            },
            askConflict: { question in
                recorder.questions.withLock { $0.append(question) }
                return answer
            }
        )
        let provider = delegate.makeProvider()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.filePromiseProvider(provider, writePromiseTo: folder.appendingPathComponent(finderName)) { error in
                recorder.completion.withLock { $0.append(error.map { ($0 as? CocoaError)?.code == .userCancelled ? "userCancelled" : "\($0)" } ?? "ok") }
                continuation.resume()
            }
        }
        return recorder
    }

    @Test func noClashWritesFindersNameWithoutAsking() async throws {
        let recorder = try await run(existing: [], finderName: "a.txt", answer: .stop)
        #expect(recorder.questions.withLock { $0 }.isEmpty)
        #expect(recorder.requests.withLock { $0.map(\.fixedName) } == ["a.txt"])
    }

    @Test func replaceWritesTheOriginalName() async throws {
        let recorder = try await run(existing: ["a.txt"], finderName: "a 2.txt", answer: .init(choice: .replace))
        #expect(recorder.questions.withLock { $0.map(\.name) } == ["a.txt"])
        let request = try #require(recorder.requests.withLock { $0.first })
        #expect(request.fixedName == "a.txt" && request.conflict == .replace)
        #expect(recorder.completion.withLock { $0 } == ["ok"])
    }

    @Test func keepBothWritesFindersRenamedFile() async throws {
        let recorder = try await run(existing: ["a.txt"], finderName: "a 2.txt", answer: .init(choice: .keepBoth))
        #expect(recorder.requests.withLock { $0.map(\.fixedName) } == ["a 2.txt"])
        #expect(recorder.requests.withLock { $0.map(\.conflict) } == [.keepBoth])
    }

    @Test func anExistingFolderIsAskedAsAFolderAndNeverReplaced() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-promise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a.txt"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let questions = OSAllocatedUnfairLock(initialState: [ConflictQuestion]())
        let file = RemoteFile(name: "a.txt", path: "/sdcard/a.txt", mode: 0o100660, size: 3, modificationDate: nil)
        let delegate = FilePromiseDelegate(
            file: file, serial: "S", enqueue: { _, done in done(.done(copied: 1, skipped: 0)) },
            askConflict: { question in
                questions.withLock { $0.append(question) }
                return .init(choice: .keepBoth)
            }
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.filePromiseProvider(delegate.makeProvider(), writePromiseTo: folder.appendingPathComponent("a 2.txt")) { _ in
                continuation.resume()
            }
        }
        #expect(questions.withLock { $0.map(\.isFolder) } == [true])
    }

    @Test func skipCopiesNothingAndTellsFinderTheUserCancelled() async throws {
        let recorder = try await run(existing: ["a.txt"], finderName: "a 2.txt", answer: .init(choice: .skip))
        #expect(recorder.requests.withLock { $0 }.isEmpty)
        #expect(recorder.completion.withLock { $0 } == ["userCancelled"])
    }
}
