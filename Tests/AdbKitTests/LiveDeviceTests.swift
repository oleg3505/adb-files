import CryptoKit
import Foundation
import ImageIO
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

    @Test func selinuxProtectedFolderIsPermissionDenied() async throws {
        // Permission bits let `test -r` pass here, but SELinux blocks the listing.
        await #expect(throws: AdbError.permissionDenied("/storage/emulated")) { try await client.list("/storage/emulated") }
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

    @Test func downloadsSystemFontByteIdentical() async throws {
        let remote = "/system/fonts/NotoSerifCJK-Regular.ttc"
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-live-\(UUID().uuidString).ttc")
        defer { try? FileManager.default.removeItem(at: target) }
        let session = try await client.openTransferSession()
        let clock = ContinuousClock()
        let started = clock.now
        try await session.download(remote, to: target, modificationDate: nil) { _ in }
        let elapsed = clock.now - started
        await session.close()
        let data = try Data(contentsOf: target)
        let deviceSum = try await AdbShell.run(AdbShell.command("sha1sum", [remote]), serial: liveSerial)
        let localSum = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(data.count == 26_283_508)
        #expect(deviceSum.hasPrefix(localSum))
        #expect(elapsed < .seconds(5), "26 MB took \(elapsed); expected ≥ 5 MB/s even in debug")
    }

    @Test func cameraJpegThumbnailFromA64KBPrefix() async throws {
        let entries = try await client.list("/sdcard/DCIM/Camera")
        let jpeg = try #require(entries.first { $0.name.lowercased().hasSuffix(".jpg") && $0.size > 200_000 })
        let session = try await client.openInteractiveSession()
        let prefix = try await session.readPrefix(jpeg.path, maxBytes: 65_536)
        await session.close()
        #expect(prefix.count == 65_536)
        let source = try #require(CGImageSourceCreateWithData(prefix as CFData, nil))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false, kCGImageSourceThumbnailMaxPixelSize: 160]
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        #expect(thumbnail != nil, "embedded EXIF thumbnail in the first 64 KB of \(jpeg.name)")
    }
}
