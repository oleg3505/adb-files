import Foundation
import Testing
@testable import AdbFiles

@Suite struct ThumbnailCacheTrimmerTests {
    private func makeCache(_ files: [(name: String, size: Int, age: TimeInterval)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-trim-\(UUID().uuidString)")
        let serial = root.appendingPathComponent("SERIAL")
        try FileManager.default.createDirectory(at: serial, withIntermediateDirectories: true)
        for file in files {
            let url = serial.appendingPathComponent(file.name)
            try Data(count: file.size).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -file.age)], ofItemAtPath: url.path)
        }
        return root
    }

    @Test func underTheLimitNothingIsRemoved() throws {
        let root = try makeCache([("a.png", 100, 10), ("b.png", 100, 20)])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ThumbnailCacheTrimmer.trim(root: root, limit: 500, target: 400)
        #expect(result == .init(before: 200, after: 200, removed: 0))
    }

    @Test func overTheLimitTheOldestGoFirstDownToTheTarget() throws {
        let root = try makeCache([("new.png", 200, 10), ("mid.png", 200, 100), ("old.png", 200, 1_000)])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ThumbnailCacheTrimmer.trim(root: root, limit: 500, target: 400)
        #expect(result == .init(before: 600, after: 400, removed: 1))
        let left = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("SERIAL").path).sorted()
        #expect(left == ["mid.png", "new.png"])
    }

    @Test func missingCacheIsFine() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-none-\(UUID().uuidString)")
        #expect(ThumbnailCacheTrimmer.trim(root: root).removed == 0)
    }
}
