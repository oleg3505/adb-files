import AdbKit
import CryptoKit
import Foundation
import os
import Testing
@testable import AdbFiles

private let serial = ProcessInfo.processInfo.environment["ADB_TEST_SERIAL"] ?? ""
private let writesAllowed = ProcessInfo.processInfo.environment["ADB_TEST_WRITE"] == "1"
/// The only folder these tests may write to on the device; removed after every test.
private let approvedRoot = "/sdcard/Download/AdbFilesTest"
/// Each live suite writes to its own subfolder, because suites run in parallel.
private let testFolder = approvedRoot + "/queue"

private func sha1(_ url: URL) throws -> String {
    var hasher = Insecure.SHA1()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Real queue + real engine against a device, no UI.
/// Run with `ADB_TEST_SERIAL=<serial> ADB_TEST_WRITE=1 swift test --filter LiveTransferQueue`.
@Suite("Live transfer queue", .enabled(if: !serial.isEmpty && writesAllowed), .serialized)
@MainActor
struct LiveTransferQueueTests {
    private let registry = SyncClientRegistry()

    private func makeQueue() -> TransferQueue {
        let registry = registry
        return TransferQueue(engine: AdbTransferEngine { serial in await registry.client(for: serial) })
    }

    /// Runs `body` with a fresh local fixture folder; always removes it and the device test folder.
    private func withFixtures(_ body: (URL) async throws -> Void) async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-live-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        var failure: Error?
        do { try await body(local) } catch { failure = error }
        try? FileManager.default.removeItem(at: local)
        _ = try? await AdbShell.run(AdbShell.command("rm -r", [testFolder]), serial: serial)
    _ = try? await AdbShell.run(AdbShell.command("rmdir", [approvedRoot]) + " 2>/dev/null", serial: serial) // only if empty
        let check = try await AdbShell.run("ls -d \(AdbShell.quote(testFolder)) 2>/dev/null || echo gone", serial: serial)
        #expect(check.trimmingCharacters(in: .whitespacesAndNewlines) == "gone", "device test folder must be removed")
        if let failure { throw failure }
    }

    private func waitFinal(_ queue: TransferQueue, timeout: Duration = .seconds(120)) async throws {
        try await waitUntil(timeout: timeout) { queue.items.allSatisfy { $0.state.isFinal } }
    }

    @Test func bigFileAndFolderRoundTrip() async throws {
        try await withFixtures { local in
            // 200 MB file + a folder tree with Cyrillic/emoji names, nested and empty folders.
            let big = local.appendingPathComponent("Великий 🎬.bin")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let writer = try FileHandle(forWritingTo: big)
            for block in 0..<200 { try writer.write(contentsOf: Data(repeating: UInt8(block), count: 1_000_000)) }
            try writer.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_650_000_000)], ofItemAtPath: big.path)
            let tree = local.appendingPathComponent("Фото 2024 📷")
            try FileManager.default.createDirectory(at: tree.appendingPathComponent("Літо/Море"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tree.appendingPathComponent("Порожня"), withIntermediateDirectories: true)
            for (path, size) in [("a.jpg", 300_000), ("Літо/b 🌊.jpg", 500_000), ("Літо/Море/c.txt", 1_000)] {
                try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 13) }).write(to: tree.appendingPathComponent(path))
            }

            let queue = makeQueue()
            let clock = ContinuousClock()
            let started = clock.now
            queue.enqueue(TransferActions.uploadRequests([big, tree], serial: serial, to: testFolder))
            try await waitFinal(queue)
            let uploadTime = clock.now - started
            #expect(queue.items.allSatisfy { if case .done = $0.state { true } else { false } }, "\(queue.items.map(\.state))")
            let bigItem = try #require(queue.items.first)
            let seconds = Double(uploadTime.components.seconds) + Double(uploadTime.components.attoseconds) / 1e18
            Logger.transfer.info("LIVE upload 200 MB + tree in \(seconds) s, publishes=\(bigItem.publishes)")
            #expect(Double(bigItem.publishes) <= seconds * 10 + 2, "≤ 10 publishes/s")

            // Download both back into a fresh Mac folder and compare.
            let back = local.appendingPathComponent("back")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            let client = registry.client(for: serial)
            let listing = try await client.list(testFolder)
            let rows = FileSorting.rows(from: listing, sort: FileSort(), showHidden: true)
            queue.clearFinished()
            queue.enqueue(TransferActions.downloadRequests(rows, serial: serial, to: back))
            try await waitFinal(queue)
            #expect(queue.items.allSatisfy { if case .done = $0.state { true } else { false } }, "\(queue.items.map(\.state))")
            #expect(try sha1(back.appendingPathComponent("Великий 🎬.bin")) == (try sha1(big)))
            let mtime = try FileManager.default.attributesOfItem(atPath: back.appendingPathComponent("Великий 🎬.bin").path)[.modificationDate] as? Date
            #expect(mtime == Date(timeIntervalSince1970: 1_650_000_000))
            for path in ["a.jpg", "Літо/b 🌊.jpg", "Літо/Море/c.txt"] {
                #expect(try sha1(back.appendingPathComponent("Фото 2024 📷/\(path)")) == (try sha1(tree.appendingPathComponent(path))))
            }
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: back.appendingPathComponent("Фото 2024 📷/Порожня").path, isDirectory: &isDirectory) && isDirectory.boolValue)

            // Upload the big file again: keep both.
            queue.clearFinished()
            queue.enqueue(TransferActions.uploadRequests([tree.appendingPathComponent("a.jpg")], serial: serial, to: testFolder))
            queue.enqueue(TransferActions.uploadRequests([tree.appendingPathComponent("a.jpg")], serial: serial, to: testFolder))
            try await waitFinal(queue)
            let names = Set(try await client.list(testFolder).map(\.name))
            #expect(names.isSuperset(of: ["a.jpg", "a 2.jpg"]))
        }
    }

    @Test func atMostTwoRunAndCancelLeavesNothing() async throws {
        try await withFixtures { local in
            var sources: [URL] = []
            for index in 0..<4 {
                let url = local.appendingPathComponent("part\(index).bin")
                try Data(count: 40_000_000).write(to: url)
                sources.append(url)
            }
            let queue = makeQueue()
            queue.enqueue(TransferActions.uploadRequests(sources, serial: serial, to: testFolder))
            var peak = 0
            while !queue.items.allSatisfy({ $0.state.isFinal }) {
                peak = max(peak, queue.items.filter { $0.state == .running || $0.state == .preparing }.count)
                // Cancel the last one once it runs; it must leave no partial file behind.
                if let last = queue.items.last, last.state == .running, last.bytesDone > 5_000_000 { queue.cancel(last.id) }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(peak == 2)
            #expect(queue.items.last?.state == .cancelled)
            try await Task.sleep(for: .milliseconds(500))
            let names = Set(try await registry.client(for: serial).list(testFolder).map(\.name))
            #expect(names == ["part0.bin", "part1.bin", "part2.bin"], "no partial part3.bin")

            // Cancel a download mid-way: no temp or target file on the Mac.
            let back = local.appendingPathComponent("back")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            let file = RemoteFile(name: "part0.bin", path: "\(testFolder)/part0.bin", mode: 0o100660, size: 40_000_000, modificationDate: nil)
            queue.clearFinished()
            let ids = queue.enqueue(TransferActions.downloadRequests(
                [FileRow(file: file, kind: "", sizeText: "", dateText: "")], serial: serial, to: back
            ))
            try await waitUntil { (queue.items.first?.bytesDone ?? 0) > 5_000_000 }
            queue.cancel(ids[0])
            try await Task.sleep(for: .milliseconds(500))
            #expect(try FileManager.default.contentsOfDirectory(atPath: back.path).isEmpty)
        }
    }
}
