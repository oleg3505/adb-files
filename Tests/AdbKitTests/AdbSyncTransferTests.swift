import Foundation
import os
import Testing
@testable import AdbKit

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func payload(_ count: Int, seed: UInt8 = 0) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// Counts bytes reported by a progress callback.
final class ByteCounter: Sendable {
    private let total = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { total.withLock { $0 } }
    var add: @Sendable (Int) -> Void { { [total] count in total.withLock { $0 += count } } }
}

@Suite("Transfers against a fake device")
struct AdbSyncTransferTests {
    @Test func downloadIsByteIdenticalWithMtimeAndNoTempLeft() async throws {
        let content = payload(200_000)
        let device = FakeDevice(files: ["/sdcard/a.bin": content])
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a.bin")
        let counter = ByteCounter()
        let session = try await client.openTransferSession()
        try await session.download("/sdcard/a.bin", to: target, modificationDate: Date(timeIntervalSince1970: 1_600_000_000), progress: counter.add)
        await session.close()
        #expect(try Data(contentsOf: target) == content)
        #expect(counter.value == content.count)
        let mtime = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
        #expect(mtime == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(!FileManager.default.fileExists(atPath: TransferIO.temporaryURL(for: target).path))
    }

    @Test func missingRemoteFileFailsAndLeavesNothing() async throws {
        let (client, server) = try await makeClient(FakeDevice())
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("x")
        let session = try await client.openTransferSession()
        await #expect(throws: AdbError.serverFailure("open failed: No such file or directory")) {
            try await session.download("/nope", to: target, modificationDate: nil) { _ in }
        }
        await session.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func sessionReopensAfterFail() async throws {
        let device = FakeDevice(files: ["/ok": payload(10)])
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try await client.openTransferSession()
        _ = try? await session.download("/nope", to: dir.appendingPathComponent("a"), modificationDate: nil) { _ in }
        try await session.download("/ok", to: dir.appendingPathComponent("b"), modificationDate: nil) { _ in }
        await session.close()
        #expect(device.log.withLock { $0 }.filter { $0 == "sync-connection" }.count == 2)
    }

    @Test func cancelAtGateLeavesNoFiles() async throws {
        let gate = TestGate()
        let device = FakeDevice(files: ["/big": payload(1_000_000)], recvChunk: 10_000, gateAfterChunks: 3, gate: gate)
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = ByteCounter()
        let session = try await client.openTransferSession()
        let target = dir.appendingPathComponent("big")
        let task = Task { try await session.download("/big", to: target, modificationDate: nil, progress: counter.add) }
        while counter.value < 30_000 { try await Task.sleep(for: .milliseconds(5)) } // held at the gate
        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(clock.now - started < .seconds(1))
        await gate.open()
        await session.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty, "no temp or target file")
    }

    @Test func steadySlowStreamDoesNotTimeOut() async throws {
        // Inactivity limit 300 ms; a chunk every 100 ms for ~1.5 s must succeed (an overall limit would fail).
        let device = FakeDevice(files: ["/slow": payload(16 * 1000)], recvChunk: 1000, chunkDelay: .milliseconds(100))
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try await client.openTransferSession(inactivity: .milliseconds(300))
        try await session.download("/slow", to: dir.appendingPathComponent("slow"), modificationDate: nil) { _ in }
        await session.close()
    }

    @Test func stalledStreamTimesOut() async throws {
        // Inactivity limit 300 ms; the device stops after 2 chunks, so the next read waits ≥ 700 ms → timeout.
        let device = FakeDevice(files: ["/stall": payload(10_000)], recvChunk: 1000, stallAfterChunks: 2)
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try await client.openTransferSession(inactivity: .milliseconds(300))
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: AdbError.timeout) {
            try await session.download("/stall", to: dir.appendingPathComponent("stall"), modificationDate: nil) { _ in }
        }
        #expect(clock.now - started < .milliseconds(700))
        await session.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func atMostTwoTransferConnectionsPerDevice() async throws {
        let gate = TestGate()
        let files = Dictionary(uniqueKeysWithValues: (0..<3).map { ("/f\($0)", payload(50_000, seed: UInt8($0))) })
        let device = FakeDevice(files: files, recvChunk: 10_000, gateAfterChunks: 1, gate: gate)
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = OSAllocatedUnfairLock(initialState: 0)
        let tasks = (0..<3).map { index in
            Task {
                let session = try await client.openTransferSession()
                opened.withLock { $0 += 1 }
                try await session.download("/f\(index)", to: dir.appendingPathComponent("f\(index)"), modificationDate: nil) { _ in }
                await session.close()
            }
        }
        while device.syncConnections.withLock({ $0.open }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(opened.withLock { $0 } == 2, "the third transfer waits for a slot")
        await gate.open()
        for task in tasks { try await task.value }
        #expect(device.syncConnections.withLock { $0.peak } == 2)
        for index in 0..<3 {
            #expect(try Data(contentsOf: dir.appendingPathComponent("f\(index)")) == files["/f\(index)"])
        }
    }

    @Test func uploadSendsBytesModeAndMtime() async throws {
        let device = FakeDevice()
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Звіт 🎉.bin")
        let content = payload(150_000)
        try content.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000), .posixPermissions: 0o640], ofItemAtPath: source.path
        )
        let counter = ByteCounter()
        let session = try await client.openTransferSession()
        try await session.upload(source, to: "/sdcard/Download/Звіт 🎉.bin", progress: counter.add)
        await session.close()
        let stored = try #require(device.received.withLock { $0["/sdcard/Download/Звіт 🎉.bin"] })
        #expect(stored.data == content)
        #expect(stored.mtime == 1_700_000_000)
        #expect(stored.mode == 0o100640)
        #expect(counter.value == content.count)
    }

    @Test func replaceUploadSwapsInTheNewFileViaAPartFile() async throws {
        let fs = FakeFileSystem(files: ["/sdcard/Download/a.txt": Data("old".utf8)])
        let (client, server) = try await makeClient(FakeDevice(fs: fs))
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.txt")
        try Data("new content".utf8).write(to: source)
        let session = try await client.openTransferSession()
        try await session.upload(source, to: "/sdcard/Download/a.txt", replace: true) { _ in }
        await session.close()
        #expect(fs.node(at: "/sdcard/Download/a.txt")?.data == Data("new content".utf8))
        #expect(!fs.paths.contains { $0.hasSuffix(".adbfiles-part") })
        #expect(fs.commands.contains { $0.hasPrefix("mv -f -- '/sdcard/Download/.a.txt.") && $0.contains(".adbfiles-part' '/sdcard/Download/a.txt'") })
    }

    @Test func cancelledReplaceUploadKeepsTheOriginalAndRemovesThePart() async throws {
        let fs = FakeFileSystem(files: ["/sdcard/Download/a.bin": Data("original".utf8)])
        var device = FakeDevice(fs: fs)
        device.sendFrameDelay = .milliseconds(20)
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.bin")
        try payload(5_000_000).write(to: source)
        let counter = ByteCounter()
        let session = try await client.openTransferSession()
        let task = Task { try await session.upload(source, to: "/sdcard/Download/a.bin", replace: true, progress: counter.add) }
        while counter.value < 300_000 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        await session.close()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while fs.commands.allSatisfy({ !$0.hasPrefix("rm -f --") }), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fs.node(at: "/sdcard/Download/a.bin")?.data == Data("original".utf8), "the original is untouched")
        #expect(!fs.paths.contains { $0.hasSuffix(".adbfiles-part") })
        #expect(!fs.commands.contains { $0.hasPrefix("mv") }, "nothing moved over the original")
        #expect(fs.commands.contains { $0.hasPrefix("rm -f -- '/sdcard/Download/.a.bin.") }, "part cleaned up")
    }

    @Test func replaceUploadOntoARemoteFolderIsRefused() async throws {
        let fs = FakeFileSystem(directories: ["/sdcard/Download/foo"], files: ["/sdcard/Download/foo/keep.txt": Data("k".utf8)])
        let (client, server) = try await makeClient(FakeDevice(fs: fs))
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("foo")
        try Data("file".utf8).write(to: source)
        let session = try await client.openTransferSession()
        await #expect(throws: AdbError.self) { try await session.upload(source, to: "/sdcard/Download/foo", replace: true) { _ in } }
        await session.close()
        #expect(fs.node(at: "/sdcard/Download/foo")?.isDirectory == true)
        #expect(fs.node(at: "/sdcard/Download/foo/keep.txt") != nil)
        #expect(!fs.commands.contains { $0.hasPrefix("mv") })
    }

    @Test func overwritingDownloadNeverDeletesALocalFolder() async throws {
        let (client, server) = try await makeClient(FakeDevice(files: ["/sdcard/Photos": payload(1000)]))
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("holiday.jpg"))
        let session = try await client.openTransferSession()
        await #expect(throws: AdbError.self) {
            try await session.download("/sdcard/Photos", to: folder, modificationDate: nil, overwrite: true) { _ in }
        }
        await session.close()
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("holiday.jpg").path), "the folder is intact")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Photos"], "no temp file left")
    }

    @Test func overwritingDownloadReplacesAFile() async throws {
        let (client, server) = try await makeClient(FakeDevice(files: ["/sdcard/a.txt": Data("new".utf8)]))
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: target)
        let session = try await client.openTransferSession()
        try await session.download("/sdcard/a.txt", to: target, modificationDate: nil, overwrite: true) { _ in }
        await session.close()
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.txt"])
    }

    @Test func uploadFailCarriesMessage() async throws {
        let (client, server) = try await makeClient(FakeDevice(failSendPaths: ["/system/x"]))
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("x")
        try Data("x".utf8).write(to: source)
        let session = try await client.openTransferSession()
        await #expect(throws: AdbError.serverFailure("couldn't create file: Read-only file system")) {
            try await session.upload(source, to: "/system/x") { _ in }
        }
        await session.close()
    }

    @Test func unreadableLocalFileIsALocalError() async throws {
        let (client, server) = try await makeClient(FakeDevice())
        defer { server.stop() }
        let dir = try tempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let source = dir.appendingPathComponent("locked")
        try Data("secret".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        let session = try await client.openTransferSession()
        await #expect(throws: AdbError.self) { try await session.upload(source, to: "/sdcard/locked") { _ in } }
        await session.close()
    }

    @Test func staleTempFromAPreviousRunIsReplaced() async throws {
        let (client, server) = try await makeClient(FakeDevice(files: ["/a": payload(1000)]))
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a")
        try Data(repeating: 0xFF, count: 5000).write(to: TransferIO.temporaryURL(for: target))
        let session = try await client.openTransferSession()
        try await session.download("/a", to: target, modificationDate: nil) { _ in }
        await session.close()
        #expect(try Data(contentsOf: target) == payload(1000))
    }

    @Test func existingTargetIsNeverOverwritten() async throws {
        let (client, server) = try await makeClient(FakeDevice(files: ["/a": payload(1000)]))
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a")
        try Data("mine".utf8).write(to: target)
        let session = try await client.openTransferSession()
        await #expect(throws: AdbError.localFileExists(target.path)) {
            try await session.download("/a", to: target, modificationDate: nil) { _ in }
        }
        await session.close()
        #expect(try Data(contentsOf: target) == Data("mine".utf8))
        #expect(!FileManager.default.fileExists(atPath: TransferIO.temporaryURL(for: target).path))
    }

    @Test func walkIsRecursiveAndSkipsSymlinks() async throws {
        let device = FakeDevice(
            listings: ["/r": ["sub", "empty", "a.txt", "link"], "/r/sub": ["b.txt"]],
            files: ["/r/a.txt": payload(3), "/r/sub/b.txt": payload(4)],
            directories: ["/r/sub", "/r/empty"], symlinks: ["/r/link"]
        )
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let session = try await client.openTransferSession()
        let entries = try await session.walk("/r")
        await session.close()
        #expect(Set(entries.map(\.relativePath)) == ["sub", "empty", "a.txt", "sub/b.txt"])
        #expect(entries.firstIndex { $0.relativePath == "sub" }! < entries.firstIndex { $0.relativePath == "sub/b.txt" }!)
    }

    @Test func folderDownloadContinuesPastFailuresAndRetrySkipsDoneFiles() async throws {
        var device = FakeDevice(
            listings: ["/r": ["sub", "empty", "a.txt", "gone.txt"], "/r/sub": ["b.txt"]],
            files: ["/r/a.txt": payload(300), "/r/sub/b.txt": payload(400)],
            directories: ["/r/sub", "/r/empty"]
        )
        let (client, server) = try await makeClient(device)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("r")
        var session = try await client.openTransferSession()
        let entries = try await session.walk("/r")
        let first = try await session.downloadFolder("/r", into: root, entries: entries) { _ in }
        await session.close()
        server.stop()
        #expect(first.copied == 2)
        #expect(first.failures.keys.sorted() == ["gone.txt"], "unreadable file fails, the rest is copied")
        #expect(try Data(contentsOf: root.appendingPathComponent("sub/b.txt")) == payload(400))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty").path, isDirectory: &isDirectory) && isDirectory.boolValue)

        // Retry into the same root: completed files are skipped (same size + mtime), the missing one is fetched.
        device.files["/r/gone.txt"] = payload(5)
        let (client2, server2) = try await makeClient(device)
        defer { server2.stop() }
        session = try await client2.openTransferSession()
        let retryEntries = try await session.walk("/r")
        let second = try await session.downloadFolder("/r", into: root, entries: retryEntries) { _ in }
        await session.close()
        #expect(second.skipped == 2)
        #expect(second.copied == 1)
        #expect(second.failures.isEmpty)
    }

    @Test func folderUploadSkipsUnreadableFilesAndCreatesEmptyFolders() async throws {
        let device = FakeDevice()
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        let root = dir.appendingPathComponent("Фото")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("locked.bin").path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try payload(10).write(to: root.appendingPathComponent("a.bin"))
        try payload(20).write(to: root.appendingPathComponent("inner/b.bin"))
        try payload(30).write(to: root.appendingPathComponent("locked.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.appendingPathComponent("locked.bin").path)

        let session = try await client.openTransferSession()
        let result = try await session.uploadFolder(root, to: "/sdcard/Фото", entries: try TransferIO.walkLocal(root)) { _ in }
        await session.close()
        #expect(result.copied == 2)
        #expect(result.failures.keys.sorted() == ["locked.bin"])
        #expect(device.received.withLock { $0["/sdcard/Фото/inner/b.bin"]?.data } == payload(20))
        #expect(device.log.withLock { $0 }.contains("shell:mkdir -p '/sdcard/Фото' '/sdcard/Фото/empty' && echo ok || echo fail"))
    }

    @Test func failedMkdirIsRecordedNotSilent() async throws {
        let (client, server) = try await makeClient(FakeDevice(shellReply: "fail\n"))
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("only-empty")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("e"), withIntermediateDirectories: true)
        let session = try await client.openTransferSession()
        let result = try await session.uploadFolder(root, to: "/system/x", entries: try TransferIO.walkLocal(root)) { _ in }
        await session.close()
        #expect(result.failures.keys.sorted() == [".", "e"])
    }

    @Test func caseOnlyNameClashIsAFailureNotAnOverwrite() async throws {
        let device = FakeDevice(listings: ["/r": ["IMG.jpg", "img.jpg"]], files: ["/r/IMG.jpg": payload(10, seed: 1), "/r/img.jpg": payload(20, seed: 2)])
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("r")
        let session = try await client.openTransferSession()
        let result = try await session.downloadFolder("/r", into: root, entries: try await session.walk("/r")) { _ in }
        await session.close()
        #expect(result.copied == 1)
        #expect(result.failures.count == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent("IMG.jpg")) == payload(10, seed: 1), "the first file is not overwritten")
    }

    @Test func disconnectEndsTransferPromptly() async throws {
        let gate = TestGate()
        let device = FakeDevice(files: ["/big": payload(500_000)], recvChunk: 10_000, gateAfterChunks: 2, gate: gate)
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = ByteCounter()
        let session = try await client.openTransferSession()
        let task = Task { try await session.download("/big", to: dir.appendingPathComponent("big"), modificationDate: nil, progress: counter.add) }
        while counter.value < 20_000 { try await Task.sleep(for: .milliseconds(5)) }
        let clock = ContinuousClock()
        let started = clock.now
        await client.disconnect()
        await #expect(throws: AdbError.connectionClosed) { try await task.value }
        #expect(clock.now - started < .seconds(1))
        await gate.open()
        await session.close()
    }

    @Test func readPrefixReturnsExactlyNBytesAndTheSessionStillWorks() async throws {
        let device = FakeDevice(files: ["/big.jpg": payload(1_000_000), "/small.txt": payload(100)], recvChunk: 8_192)
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let session = try await client.openInteractiveSession()
        let prefix = try await session.readPrefix("/big.jpg", maxBytes: 65_536)
        #expect(prefix == payload(1_000_000).prefix(65_536))
        let whole = try await session.readPrefix("/small.txt", maxBytes: 65_536)
        #expect(whole == payload(100), "a prefix larger than the file returns the whole file")
        await session.close()
    }

    @Test func interactiveSessionIsIndependentOfTransferSlots() async throws {
        let gate = TestGate()
        let device = FakeDevice(files: ["/a": payload(50_000), "/b": payload(50_000), "/c": payload(10)],
                                recvChunk: 10_000, gateAfterChunks: 1, gate: gate)
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transfers = ["/a", "/b"].map { path in
            Task {
                let session = try await client.openTransferSession()
                try await session.download(path, to: dir.appendingPathComponent(String(path.dropFirst())), modificationDate: nil) { _ in }
                await session.close()
            }
        }
        while device.syncConnections.withLock({ $0.open }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let interactive = try await client.openInteractiveSession(priority: .high) // must not wait for a transfer slot
        #expect(try await interactive.readPrefix("/c", maxBytes: 1_000) == payload(10))
        await interactive.close()
        #expect(device.syncConnections.withLock { $0.peak } == 3)
        await gate.open()
        for task in transfers { try await task.value }
    }
}

@Suite("Async limiter priority")
struct AsyncLimiterTests {
    @Test func highPriorityWaiterGoesBeforeQueuedNormalOnes() async throws {
        let limiter = AsyncLimiter(limit: 1)
        try await limiter.acquire()  // slot taken
        let order = OSAllocatedUnfairLock(initialState: [String]())
        var tasks: [Task<Void, Error>] = []
        for name in ["n1", "n2", "n3"] {
            tasks.append(Task {
                try await limiter.acquire(priority: .normal)
                order.withLock { $0.append(name) }
                await limiter.release()
            })
            try await Task.sleep(for: .milliseconds(20)) // enqueue in a known order
        }
        tasks.append(Task {
            try await limiter.acquire(priority: .high)
            order.withLock { $0.append("high") }
            await limiter.release()
        })
        try await Task.sleep(for: .milliseconds(20))
        await limiter.release()
        for task in tasks { try await task.value }
        #expect(order.withLock { $0 } == ["high", "n1", "n2", "n3"])
    }
}
