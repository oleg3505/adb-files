import CryptoKit
import Foundation
import os
import Testing
@testable import AdbKit

private let writeSerial = ProcessInfo.processInfo.environment["ADB_TEST_SERIAL"] ?? ""
private let writesAllowed = ProcessInfo.processInfo.environment["ADB_TEST_WRITE"] == "1"
/// The only folder these tests may write to on the device; removed after every test.
private let approvedRoot = "/sdcard/Download/AdbFilesTest"
/// Each live suite writes to its own subfolder, because suites run in parallel.
private let testFolder = approvedRoot + "/write"

private func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Runs `body`, then always removes the test folder on the device (also when `body` throws).
private func withTestFolder(_ body: () async throws -> Void) async throws {
    var failure: Error?
    do { try await body() } catch { failure = error }
    _ = try? await AdbShell.run(AdbShell.command("rm -r", [testFolder]), serial: writeSerial)
    _ = try? await AdbShell.run(AdbShell.command("rmdir", [approvedRoot]) + " 2>/dev/null", serial: writeSerial) // only if empty
    let check = try await AdbShell.run("ls -d \(AdbShell.quote(testFolder)) 2>/dev/null || echo gone", serial: writeSerial)
    #expect(check.trimmingCharacters(in: .whitespacesAndNewlines) == "gone", "test folder must be removed")
    if let failure { throw failure }
}

/// Writes to the device. Run with `ADB_TEST_SERIAL=<serial> ADB_TEST_WRITE=1 swift test --filter LiveWrite`.
@Suite("Live device writes", .enabled(if: !writeSerial.isEmpty && writesAllowed), .serialized)
struct LiveWriteTests {
    let client = AdbSyncClient(serial: writeSerial)

    @Test func uploadAndDownloadRoundTrip() async throws {
        try await withTestFolder {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("Звіт 🎉.bin")
            let content = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            try content.write(to: source)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path)

            let session = try await client.openTransferSession()
            try await session.upload(source, to: "\(testFolder)/Звіт 🎉.bin") { _ in }
            let stat = try await session.lstat("\(testFolder)/Звіт 🎉.bin")
            #expect(stat.size == UInt64(content.count))
            #expect(stat.mtime == 1_700_000_000)
            let back = dir.appendingPathComponent("back.bin")
            try await session.download("\(testFolder)/Звіт 🎉.bin", to: back, modificationDate: Date(timeIntervalSince1970: TimeInterval(stat.mtime))) { _ in }
            await session.close()
            #expect(sha1(try Data(contentsOf: back)) == sha1(content))
        }
    }

    @Test func cancelledUploadLeavesNoPartialFile() async throws {
        try await withTestFolder {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("big.bin")
            try Data(count: 60_000_000).write(to: source)
            _ = try await AdbShell.run(AdbShell.command("mkdir -p", [testFolder]), serial: writeSerial)

            let sent = OSAllocatedUnfairLock(initialState: 0)
            let session = try await client.openTransferSession()
            let task = Task { try await session.upload(source, to: "\(testFolder)/big.bin") { count in sent.withLock { $0 += count } } }
            while sent.withLock({ $0 }) < 5_000_000 { try await Task.sleep(for: .milliseconds(10)) }
            task.cancel()
            _ = try? await task.value
            await session.close()
            try await Task.sleep(for: .milliseconds(500)) // adbd removes the partial file after the disconnect
            let stat = try await client.lstat("\(testFolder)/big.bin")
            #expect(stat.errorCode == 2, "adbd must have deleted the partial upload")
        }
    }
}
