import AdbKit
import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Thumbnails for one device: memory and disk cache, device reads one at a time (the interactive connection),
/// at most `maxDecodes` decodes at once, duplicate requests sharing one task.
///
/// A request that every caller cancelled is dropped: its result is never cached (not even as "no thumbnail")
/// and never reported as an error.
actor ThumbnailService {
    static let pixelSize = 160

    private let serial: String
    private let source: any ThumbnailSource
    private let directory: URL
    private let decodeGate: CountingGate
    /// Bytes → thumbnail PNG. The orientation is set for an extracted EXIF thumbnail, nil for a whole image file.
    private let decoder: @Sendable (Data, Int?) -> Data?
    private let signposter = OSSignposter(logger: .ui)

    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private let memoryLimit = 600
    private var inflight: [String: (id: UUID, task: Task<Data?, Never>, waiters: Int)] = [:]

    /// - Parameter decoder: Turns bytes into thumbnail PNG data; injectable for tests.
    init(
        serial: String, source: any ThumbnailSource, cacheRoot: URL = ThumbnailService.defaultCacheRoot, maxDecodes: Int = 2,
        decoder: @escaping @Sendable (Data, Int?) -> Data? = { ThumbnailService.makeThumbnail(from: $0, exifOrientation: $1) }
    ) {
        self.serial = serial
        self.source = source
        self.decoder = decoder
        self.directory = cacheRoot.appendingPathComponent(Self.safeName(serial), isDirectory: true)
        self.decodeGate = CountingGate(limit: maxDecodes)
    }

    static var defaultCacheRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("AdbFiles/thumbs", isDirectory: true)
    }

    /// Cache key: path, size and modification time (a changed file gets a new thumbnail).
    nonisolated static func key(for file: RemoteFile) -> String {
        let mtime = Int64(file.modificationDate?.timeIntervalSince1970 ?? 0)
        let digest = SHA256.hash(data: Data("\(file.path)|\(file.size)|\(mtime)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// PNG data of the thumbnail, or nil when the file has none (or the request was cancelled).
    func thumbnail(for file: RemoteFile) async -> Data? {
        let strategy = ThumbnailStrategy.choose(for: file)
        guard strategy != .none else { return nil }
        let key = Self.key(for: file)
        if let cached = memory[key] {
            Logger.ui.debug("thumb source=memory path=\(file.path, privacy: .public)")
            return cached
        }
        let diskURL = directory.appendingPathComponent(key + ".png")
        if let data = try? Data(contentsOf: diskURL) {
            remember(key, data)
            Logger.ui.info("thumb source=disk path=\(file.path, privacy: .public)")
            return data
        }
        if let existing = inflight[key] {
            inflight[key]?.waiters += 1
            return await existing.task.value
        }
        let id = UUID()
        let task = Task { await self.generate(file, strategy: strategy, key: key, id: id, diskURL: diskURL) }
        inflight[key] = (id, task, 1)
        return await task.value
    }

    /// The caller no longer needs the thumbnail of `file`; the read is cancelled when nobody else waits for it.
    func cancel(_ file: RemoteFile) {
        let key = Self.key(for: file)
        guard var entry = inflight[key] else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            inflight[key] = nil
            Logger.ui.info("thumb cancel path=\(file.path, privacy: .public)")
        } else {
            inflight[key] = entry
        }
    }

    /// Cancels everything in flight (device gone, browser closed, folder changed).
    func cancelAll() {
        for entry in inflight.values { entry.task.cancel() }
        if !inflight.isEmpty { Logger.ui.info("thumb cancel all count=\(self.inflight.count)") }
        inflight.removeAll()
    }

    // MARK: - Generation

    private func generate(_ file: RemoteFile, strategy: ThumbnailStrategy, key: String, id: UUID, diskURL: URL) async -> Data? {
        let interval = signposter.beginInterval("thumbnail", id: signposter.makeSignpostID(), "\(file.name, privacy: .public)")
        defer { signposter.endInterval("thumbnail", interval) }
        let clock = ContinuousClock()
        let started = clock.now
        var bytesRead = 0
        do {
            var png: Data?
            switch strategy {
            case .embedded(let prefixBytes, let fallbackToFull):
                let prefix = try await source.read(file.path, maxBytes: prefixBytes)
                bytesRead = prefix.count
                // Only a complete embedded thumbnail counts; a truncated main image must never be decoded.
                if let exif = ExifThumbnail.extract(from: prefix) {
                    png = try await decode(exif.jpeg, exifOrientation: exif.orientation)
                }
                if png == nil, fallbackToFull {
                    let whole = try await source.read(file.path, maxBytes: Int(ThumbnailStrategy.fullReadLimit))
                    bytesRead += whole.count
                    png = try await decode(whole, exifOrientation: nil)
                }
            case .full:
                let whole = try await source.read(file.path, maxBytes: Int(ThumbnailStrategy.fullReadLimit))
                bytesRead = whole.count
                png = try await decode(whole, exifOrientation: nil)
            case .none:
                png = nil
            }
            try Task.checkCancellation()
            finish(key, id)
            guard let png else { return nil }
            remember(key, png)
            write(png, to: diskURL)
            Logger.ui.info(
                "thumb source=device path=\(file.path, privacy: .public) bytes=\(bytesRead) ms=\(Int((clock.now - started) / .milliseconds(1)))"
            )
            return png
        } catch {
            // Cancelled (or the device went away): nothing is cached, nothing is reported.
            finish(key, id)
            if !(error is CancellationError) && !Task.isCancelled {
                Logger.ui.debug("thumb unavailable path=\(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    /// Decodes on a background task (never on this actor, so other requests keep flowing), at most `maxDecodes` at once.
    private func decode(_ data: Data, exifOrientation: Int?) async throws -> Data? {
        try await decodeGate.acquire()
        defer { Task { await decodeGate.release() } }
        try Task.checkCancellation()
        let decoder = self.decoder
        return await Task.detached(priority: .utility) { decoder(data, exifOrientation) }.value
    }

    /// Scales complete image data to a PNG of at most `pixelSize`. `exifOrientation` is applied to an extracted
    /// EXIF thumbnail (which carries no orientation of its own); whole files use their own orientation tag.
    nonisolated static func makeThumbnail(from data: Data, exifOrientation: Int?) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let exifOrientation, exifOrientation != 1, let rotated = oriented(image, exifOrientation) { image = rotated }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Applies an EXIF orientation (2…8) to an image.
    nonisolated static func oriented(_ image: CGImage, _ orientation: Int) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let swaps = (5...8).contains(orientation)
        let size = swaps ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var transform = CGAffineTransform.identity
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default: return image
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Caches

    /// Clears the in-flight entry only if it is still this generation (a newer request may have replaced it).
    private func finish(_ key: String, _ id: UUID) {
        if inflight[key]?.id == id { inflight[key] = nil }
    }

    private func remember(_ key: String, _ data: Data) {
        if memory[key] == nil { memoryOrder.append(key) }
        memory[key] = data
        if memoryOrder.count > memoryLimit {
            let evicted = memoryOrder.removeFirst()
            memory[evicted] = nil
        }
    }

    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func safeName(_ serial: String) -> String {
        serial.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.reduce(into: "") { $0.append($1) }
    }
}

/// A small FIFO counting semaphore for async code.
actor CountingGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async throws {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Woken with the slot; if the task was cancelled meanwhile, give the slot back before throwing.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}
