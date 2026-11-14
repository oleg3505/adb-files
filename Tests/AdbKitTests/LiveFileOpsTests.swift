import Foundation
import Testing
@testable import AdbKit

private let serial = ProcessInfo.processInfo.environment["ADB_TEST_SERIAL"] ?? ""
private let writesAllowed = ProcessInfo.processInfo.environment["ADB_TEST_WRITE"] == "1"
private let approvedRoot = "/sdcard/Download/AdbFilesTest"
/// Each live suite writes to its own subfolder, because suites run in parallel.
private let testFolder = approvedRoot + "/fileops"

/// File operations against a real device, only inside `testFolder`.
/// Run with `ADB_TEST_SERIAL=<serial> ADB_TEST_WRITE=1 swift test --filter LiveFileOps`.
@Suite("Live file operations", .enabled(if: !serial.isEmpty && writesAllowed), .serialized)
struct LiveFileOpsTests {
    let client = AdbSyncClient(serial: serial)
    var ops: AdbFileOperations { AdbFileOperations(serial: serial, client: client) }

    private func withTestFolder(_ body: () async throws -> Void) async throws {
        var failure: Error?
        do {
            try await AdbShell.runChecked(AdbShell.command("mkdir -p --", [testFolder]), serial: serial)
            try await body()
        } catch {
            failure = error
        }
        _ = try? await AdbShell.run(AdbShell.command("rm -r --", [testFolder]), serial: serial)
        _ = try? await AdbShell.run(AdbShell.command("rmdir --", [approvedRoot]) + " 2>/dev/null", serial: serial)
        let check = try await AdbShell.run("ls -d \(AdbShell.quote(testFolder)) 2>/dev/null || echo gone", serial: serial)
        #expect(check.trimmingCharacters(in: .whitespacesAndNewlines) == "gone", "test folder must be removed")
        if let failure { throw failure }
    }

    private func names(_ folder: String) async throws -> Set<String> {
        Set(try await client.list(folder).map(\.name))
    }

    @Test func roundTripWithHostileNames() async throws {
        try await withTestFolder {
            let folder = testFolder
            try await ops.makeDirectory("\(folder)/-rf")
            try await ops.makeDirectory("\(folder)/Папка 📁")
            #expect(try await names(folder) == ["-rf", "Папка 📁"])

            // A file to play with (created with the same quoting helper).
            try await AdbShell.runChecked(AdbShell.command("touch --", ["\(folder)/it's a.txt"]), serial: serial)
            let renamed = try await ops.rename("\(folder)/it's a.txt", to: "Звіт 🎉.txt")
            #expect(renamed == "\(folder)/Звіт 🎉.txt")

            // Case-only rename on case-insensitive shared storage.
            try await ops.rename(renamed, to: "ЗВІТ 🎉.txt")
            #expect(try await names(folder).contains("ЗВІТ 🎉.txt"))
            #expect(!(try await names(folder).contains("Звіт 🎉.txt")))

            // Clash (case-insensitive) is refused.
            await #expect(throws: AdbError.alreadyExists("\(folder)/папка 📁")) {
                try await ops.makeDirectory("\(folder)/папка 📁")
            }

            // Copy keeps the source and the mtime; move removes the source.
            let copied = await ops.copy(["\(folder)/ЗВІТ 🎉.txt"], into: "\(folder)/-rf")
            #expect(copied["\(folder)/ЗВІТ 🎉.txt"] == .success("\(folder)/-rf/ЗВІТ 🎉.txt"))
            let sourceTime = try await client.lstat("\(folder)/ЗВІТ 🎉.txt").mtime
            #expect(try await client.lstat("\(folder)/-rf/ЗВІТ 🎉.txt").mtime == sourceTime)
            let moved = await ops.move(["\(folder)/ЗВІТ 🎉.txt"], into: "\(folder)/Папка 📁")
            #expect(moved["\(folder)/ЗВІТ 🎉.txt"] == .success("\(folder)/Папка 📁/ЗВІТ 🎉.txt"))
            #expect(!(try await names(folder).contains("ЗВІТ 🎉.txt")))

            // Moving into a folder that already has that name is refused; nothing is overwritten.
            let clash = await ops.move(["\(folder)/-rf/ЗВІТ 🎉.txt"], into: "\(folder)/Папка 📁")
            #expect(clash["\(folder)/-rf/ЗВІТ 🎉.txt"] == .failure(.alreadyExists("\(folder)/Папка 📁/ЗВІТ 🎉.txt")))

            // Delete both folders recursively.
            let deleted = await ops.delete(["\(folder)/-rf", "\(folder)/Папка 📁"])
            #expect(deleted.values.allSatisfy { if case .success = $0 { true } else { false } })
            #expect(try await names(folder).isEmpty)
        }
    }
}
