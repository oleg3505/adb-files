import AdbKit
import CoreGraphics
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import AdbFiles

/// Serves bytes per path; records reads; can hold reads at a gate.
final class FakeThumbSource: ThumbnailSource {
    private let files: [String: Data]
    private let reads = OSAllocatedUnfairLock(initialState: [(String, Int)]())
    let gate: Gate?

    init(_ files: [String: Data], gate: Gate? = nil) {
        self.files = files
        self.gate = gate
    }

    var readLog: [(String, Int)] { reads.withLock { $0 } }

    func read(_ path: String, maxBytes: Int) async throws -> Data {
        reads.withLock { $0.append((path, maxBytes)) }
        await gate?.wait()
        try Task.checkCancellation()
        guard let data = files[path] else { throw AdbError.notFound(path) }
        return data.prefix(maxBytes)
    }
}

/// A noisy (hard to compress) JPEG, optionally with an embedded EXIF thumbnail.
func makeJPEG(width: Int = 1600, height: Int = 1200, embedThumbnail: Bool) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    var generator = SystemRandomNumberGenerator()
    for y in stride(from: 0, to: height, by: 8) {
        for x in stride(from: 0, to: width, by: 8) {
            context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                 blue: .random(in: 0...1, using: &generator), alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 8, height: 8))
        }
    }
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    let options: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: embedThumbnail, kCGImageDestinationLossyCompressionQuality: 0.9]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func remote(_ name: String, size: UInt64, mtime: TimeInterval = 1_700_000_000) -> RemoteFile {
    RemoteFile(name: name, path: "/sdcard/DCIM/\(name)", mode: 0o100660, size: size, modificationDate: Date(timeIntervalSince1970: mtime))
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("adbfiles-thumbs-\(UUID().uuidString)")
}

@Suite("Thumbnail service")
struct ThumbnailServiceTests {
    static let withThumb = makeJPEG(embedThumbnail: true)
    static let withoutThumb = makeJPEG(width: 800, height: 600, embedThumbnail: false)

    @Test func keyChangesWithSizeAndMtimeOnly() {
        let a = remote("a.jpg", size: 10)
        #expect(ThumbnailService.key(for: a) == ThumbnailService.key(for: remote("a.jpg", size: 10)))
        #expect(ThumbnailService.key(for: a) != ThumbnailService.key(for: remote("a.jpg", size: 11)))
        #expect(ThumbnailService.key(for: a) != ThumbnailService.key(for: remote("a.jpg", size: 10, mtime: 1)))
        #expect(ThumbnailService.key(for: a) != ThumbnailService.key(for: remote("b.jpg", size: 10)))
    }

    @Test(arguments: [
        ("a.JPG", UInt64(3_000_000), ThumbnailStrategy.embedded(prefixBytes: 65_536, fallbackToFull: true)),
        ("a.heic", UInt64(30_000_000), ThumbnailStrategy.embedded(prefixBytes: 65_536, fallbackToFull: false)),
        ("a.png", UInt64(2_000_000), ThumbnailStrategy.full),
        ("a.png", UInt64(20_000_000), ThumbnailStrategy.none),
        ("a.mp4", UInt64(300_000_000), ThumbnailStrategy.none),
        ("notes.txt", UInt64(10), ThumbnailStrategy.none),
    ])
    func strategyByTypeAndSize(name: String, size: UInt64, expected: ThumbnailStrategy) {
        #expect(ThumbnailStrategy.choose(for: remote(name, size: size)) == expected)
    }

    @Test func extractorFindsTheEmbeddedThumbnailOnlyWhenPresentAndComplete() throws {
        let found = try #require(ExifThumbnail.extract(from: Self.withThumb.prefix(65_536)))
        #expect(found.jpeg.starts(with: [0xFF, 0xD8]))
        #expect(ExifThumbnail.extract(from: Self.withoutThumb.prefix(65_536)) == nil)
        #expect(ExifThumbnail.extract(from: Self.withThumb.prefix(200)) == nil, "truncated thumbnail is not used")
        #expect(ExifThumbnail.extract(from: Data("not a jpeg".utf8)) == nil)
    }

    @Test func orientationSixRotatesToPortrait() throws {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rotated = try #require(ThumbnailService.oriented(context.makeImage()!, 6))
        #expect(rotated.width == 20 && rotated.height == 40)
    }

    @Test func embeddedThumbnailFromA64KBPrefix() async throws {
        #expect(Self.withThumb.count > 200_000)
        let file = remote("a.jpg", size: UInt64(Self.withThumb.count))
        let source = FakeThumbSource([file.path: Self.withThumb])
        let service = ThumbnailService(serial: "S", source: source, cacheRoot: tempRoot())
        let png = try #require(await service.thumbnail(for: file))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(source.readLog.map(\.1) == [65_536], "only the prefix is read")
    }

    @Test func jpegWithoutExifFallsBackToAFullReadWhenSmall() async throws {
        let file = remote("b.jpg", size: UInt64(Self.withoutThumb.count))
        let source = FakeThumbSource([file.path: Self.withoutThumb])
        let service = ThumbnailService(serial: "S", source: source, cacheRoot: tempRoot())
        #expect(await service.thumbnail(for: file) != nil)
        #expect(source.readLog.map(\.1) == [65_536, 10 * 1024 * 1024])
    }

    @Test func bigJpegWithoutExifKeepsTheIcon() async throws {
        let file = remote("c.jpg", size: 20_000_000)
        let source = FakeThumbSource([file.path: Self.withoutThumb])
        let service = ThumbnailService(serial: "S", source: source, cacheRoot: tempRoot())
        #expect(await service.thumbnail(for: file) == nil)
        #expect(source.readLog.map(\.1) == [65_536])
    }

    @Test func diskCacheSurvivesARelaunch() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = remote("a.jpg", size: UInt64(Self.withThumb.count))
        let first = FakeThumbSource([file.path: Self.withThumb])
        #expect(await ThumbnailService(serial: "S", source: first, cacheRoot: root).thumbnail(for: file) != nil)
        let second = FakeThumbSource([file.path: Self.withThumb])
        #expect(await ThumbnailService(serial: "S", source: second, cacheRoot: root).thumbnail(for: file) != nil)
        #expect(second.readLog.isEmpty, "served from disk, no device read")
    }

    @Test func duplicateRequestsShareOneRead() async throws {
        let gate = Gate()
        let file = remote("a.jpg", size: UInt64(Self.withThumb.count))
        let source = FakeThumbSource([file.path: Self.withThumb], gate: gate)
        let service = ThumbnailService(serial: "S", source: source, cacheRoot: tempRoot())
        let requests = (0..<3).map { _ in Task { await service.thumbnail(for: file) } }
        while source.readLog.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        await gate.open()
        for request in requests { #expect(await request.value != nil) }
        #expect(source.readLog.count == 1)
    }

    @Test func atMostTwoDecodesAtOnce() async throws {
        let files = (0..<6).map { remote("p\($0).png", size: 1000) }
        let source = FakeThumbSource(Dictionary(uniqueKeysWithValues: files.map { ($0.path, Data(repeating: 1, count: 1000)) }))
        let counter = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
        let service = ThumbnailService(serial: "S", source: source, cacheRoot: tempRoot()) { _, _ in
            counter.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            Thread.sleep(forTimeInterval: 0.05)
            counter.withLock { $0.now -= 1 }
            return Data([0x89])
        }
        await withTaskGroup(of: Void.self) { group in
            for file in files { group.addTask { _ = await service.thumbnail(for: file) } }
        }
        #expect(counter.withLock { $0.peak } <= 2)
        #expect(counter.withLock { $0.peak } == 2, "the limit is reached, so it is the limit that holds it")
    }

    @Test func cancelledRequestCachesNothingAndCanBeRetried() async throws {
        let gate = Gate()
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = remote("a.jpg", size: UInt64(Self.withThumb.count))
        let source = FakeThumbSource([file.path: Self.withThumb], gate: gate)
        let service = ThumbnailService(serial: "S", source: source, cacheRoot: root)
        let request = Task { await service.thumbnail(for: file) }
        while source.readLog.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await service.cancel(file)
        await gate.open()
        #expect(await request.value == nil, "a cancelled request yields nothing")
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("S").path)) ?? []
        #expect(cached.isEmpty, "nothing written for a cancelled request")
        #expect(await service.thumbnail(for: file) != nil, "a later request generates it")
        #expect(source.readLog.count == 2)
    }

    @Test func cancelAllStopsPendingReads() async throws {
        let gate = Gate()
        let files = (0..<3).map { remote("x\($0).jpg", size: UInt64(Self.withThumb.count)) }
        let source = FakeThumbSource(Dictionary(uniqueKeysWithValues: files.map { ($0.path, Self.withThumb) }), gate: gate)
        let service = ThumbnailService(serial: "S", source: source, cacheRoot: tempRoot())
        let requests = files.map { file in Task { await service.thumbnail(for: file) } }
        while source.readLog.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        await service.cancelAll()
        await gate.open()
        for request in requests { #expect(await request.value == nil) }
    }
}
