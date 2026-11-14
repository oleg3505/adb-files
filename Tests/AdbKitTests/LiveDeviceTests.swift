import Foundation
import Testing
@testable import AdbKit

private let liveSerial = ProcessInfo.processInfo.environment["ADB_TEST_SERIAL"] ?? ""

/// Talks to a real device. Run with `ADB_TEST_SERIAL=<serial> swift test --filter LiveDevice`.
/// Read-only: never creates or changes files on the device.
@Suite("Live device", .enabled(if: !liveSerial.isEmpty), .serialized)
struct LiveDeviceTests {
    let client = AdbSyncClient(serial: liveSerial)

    @Test func listsInternalStorage() async throws {
        let entries = try await client.list("/sdcard")
        #expect(entries.contains { $0.name == "Download" && $0.isDirectory })
        #expect(!entries.contains { $0.name == "." || $0.name == ".." })
    }

    @Test func dataIsPermissionDenied() async throws {
        await #expect(throws: AdbError.permissionDenied("/data")) { try await client.list("/data") }
    }

    @Test func existingEmptyFolderIsEmpty() async throws {
        // An app-created folder that is empty on the test phone (verified with `find -empty`).
        let entries = try await client.list("/sdcard/Android/media/com.google.android.gms")
        #expect(entries.isEmpty)
    }

    @Test func missingPathIsNotFound() async throws {
        await #expect(throws: AdbError.notFound("/sdcard/adbfiles-definitely-missing")) {
            try await client.list("/sdcard/adbfiles-definitely-missing")
        }
    }

    @Test func largeFolderListsWithinBudget() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let entries = try await client.list("/sdcard/DCIM/Camera")
        let elapsed = clock.now - started
        #expect(entries.count > 1000)
        #expect(elapsed < .seconds(5), "listing \(entries.count) entries took \(elapsed)")
    }

    @Test func connectionIsReusedAcrossCalls() async throws {
        for _ in 0..<5 { _ = try await client.list("/sdcard") }
        let stat = try await client.lstat("/sdcard/")
        #expect(stat.isDirectory)
    }
}
