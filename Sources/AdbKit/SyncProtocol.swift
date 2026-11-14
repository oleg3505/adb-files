import Foundation

/// Framing for the ADB sync service (after `sync:`), per AOSP `file_sync_protocol.h`.
///
/// A request is a 4-byte ASCII id, a little-endian `UInt32` path length (at most 1024) and the UTF-8 path.
public enum SyncProtocol {
    /// Maximum path length accepted by adbd.
    public static let maxPathLength = 1024

    /// Request ids sent by the client.
    public enum Request: String, Sendable {
        case list = "LIST"
        case listV2 = "LIS2"
        case lstat = "STAT"
        case lstatV2 = "LST2"
        case recv = "RECV"
        case quit = "QUIT"
    }

    /// Largest `DATA` payload adbd accepts or sends (`SYNC_DATA_MAX`).
    public static let maxDataChunk = 64 * 1024

    /// Encodes `SEND <path>,<mode>`: the mode is written in decimal, like `adb push` does.
    /// - Throws: `AdbError.invalidRequest` when the spec exceeds 1024 bytes.
    public static func encodeSendRequest(path: String, mode: UInt32) throws(AdbError) -> Data {
        let spec = Data("\(path),\(mode)".utf8)
        guard spec.count <= maxPathLength else {
            throw .invalidRequest("path is \(spec.count) bytes, maximum is \(maxPathLength)")
        }
        var data = Data("SEND".utf8)
        data.appendLittleEndian(UInt32(spec.count))
        data.append(spec)
        return data
    }

    /// Encodes one `DATA` chunk (at most `maxDataChunk` bytes).
    public static func encodeData(_ chunk: Data) -> Data {
        var data = Data("DATA".utf8)
        data.appendLittleEndian(UInt32(chunk.count))
        data.append(chunk)
        return data
    }

    /// Encodes the `DONE` that ends a `SEND`, carrying the file's modification time.
    public static func encodeDone(mtime: UInt32) -> Data {
        var data = Data("DONE".utf8)
        data.appendLittleEndian(mtime)
        return data
    }

    /// Parses the 8-byte status header that answers a `SEND`.
    /// - Returns: nil for `OKAY`, or the length of the `FAIL` message that follows.
    public static func parseStatusHeader(_ header: Data) throws(AdbError) -> Int? {
        let bytes = [UInt8](header)
        guard bytes.count == 8 else { throw .protocolError("status header is \(bytes.count) bytes, expected 8") }
        switch String(decoding: bytes[0..<4], as: UTF8.self) {
        case "OKAY": return nil
        case "FAIL": return Int(bytes.u32(at: 4))
        case let other: throw .protocolError("unexpected status \(other.debugDescription)")
        }
    }

    /// Encodes a request.
    /// - Throws: `AdbError.invalidRequest` when the UTF-8 path exceeds 1024 bytes.
    public static func encodeRequest(_ request: Request, path: String) throws(AdbError) -> Data {
        let pathBytes = Data(path.utf8)
        guard pathBytes.count <= maxPathLength else {
            throw .invalidRequest("path is \(pathBytes.count) bytes, maximum is \(maxPathLength)")
        }
        var data = Data(request.rawValue.utf8)
        data.appendLittleEndian(UInt32(pathBytes.count))
        data.append(pathBytes)
        return data
    }

    /// Byte size of an `LST2`/`STA2` reply (id included).
    public static let statV2ReplySize = 4 + 68
    /// Byte size of a `STAT` (v1) reply (id included).
    public static let statV1ReplySize = 4 + 12

    /// Decodes a complete `LST2`/`STA2` (`v2: true`) or `STAT` (`v2: false`) reply.
    public static func decodeStat(_ data: Data, v2: Bool) throws(AdbError) -> SyncStat {
        let bytes = [UInt8](data)
        let expected = v2 ? statV2ReplySize : statV1ReplySize
        guard bytes.count == expected else {
            throw .protocolError("stat reply is \(bytes.count) bytes, expected \(expected)")
        }
        let id = String(decoding: bytes[0..<4], as: UTF8.self)
        if v2 {
            guard id == "LST2" || id == "STA2" else { throw .protocolError("unexpected stat id \(id.debugDescription)") }
            return SyncStat(
                errorCode: bytes.u32(at: 4), mode: bytes.u32(at: 4 + 4 + 8 + 8), size: bytes.u64(at: 4 + 36),
                mtime: bytes.i64(at: 4 + 52)
            )
        }
        guard id == "STAT" else { throw .protocolError("unexpected stat id \(id.debugDescription)") }
        let mode = bytes.u32(at: 4)
        // v1 reports a missing path as all zeros.
        return SyncStat(errorCode: mode == 0 ? 2 : 0, mode: mode, size: UInt64(bytes.u32(at: 8)), mtime: Int64(bytes.u32(at: 12)))
    }
}

/// Result of a sync stat request.
public struct SyncStat: Sendable, Equatable {
    /// errno from the device (0 = success; 2 = no such file).
    public let errorCode: UInt32
    /// POSIX mode bits.
    public let mode: UInt32
    /// Size in bytes.
    public let size: UInt64
    /// Modification time, seconds since 1970.
    public let mtime: Int64

    /// Whether the path is a directory.
    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
}

/// Incremental decoder for a `LIST` (v1, `DENT`) or `LIS2` (v2, `DNT2`) reply stream.
///
/// Append bytes as they arrive and call `next()` until it returns nil. A partial entry is never consumed.
public struct SyncListDecoder: Sendable {
    /// Decoded unit of a listing reply.
    public enum Item: Sendable, Equatable {
        case entry(RemoteFile)
        case done
    }

    private let v2: Bool
    private let directory: String
    private var buffer: [UInt8] = []
    private var offset = 0

    private var entryBodySize: Int { v2 ? 72 : 16 }

    /// - Parameters:
    ///   - v2: true for `LIS2`/`DNT2`, false for `LIST`/`DENT`.
    ///   - directory: The listed directory, used to build each entry's path.
    public init(v2: Bool, directory: String) {
        self.v2 = v2
        self.directory = RemotePath.normalized(directory)
    }

    /// Appends received bytes.
    public mutating func append(_ data: Data) {
        if offset > 0, offset >= buffer.count / 2 {
            buffer.removeFirst(offset)
            offset = 0
        }
        buffer.append(contentsOf: data)
    }

    /// Decodes the next item, or returns nil when more bytes are needed.
    /// - Throws: `AdbError.serverFailure` on `FAIL`, `.protocolError` on unexpected bytes.
    public mutating func next() throws(AdbError) -> Item? {
        let available = buffer.count - offset
        guard available >= 4 else { return nil }
        let id = String(decoding: buffer[offset..<offset + 4], as: UTF8.self)
        switch id {
        case "DONE":
            guard available >= 4 + entryBodySize else { return nil }
            offset += 4 + entryBodySize
            return .done
        case "FAIL":
            guard available >= 8 else { return nil }
            let length = Int(buffer.u32(at: offset + 4))
            guard available >= 8 + length else { return nil }
            let message = String(decoding: buffer[offset + 8..<offset + 8 + length], as: UTF8.self)
            offset += 8 + length
            throw .serverFailure(message)
        case "DENT" where !v2, "DNT2" where v2:
            guard available >= 4 + entryBodySize else { return nil }
            let body = offset + 4
            let nameLength = Int(buffer.u32(at: body + entryBodySize - 4))
            guard available >= 4 + entryBodySize + nameLength else { return nil }
            let nameStart = body + entryBodySize
            let name = String(decoding: buffer[nameStart..<nameStart + nameLength], as: UTF8.self)
            offset = nameStart + nameLength
            // Older adbd versions pass `.` and `..` through from readdir; they are never real entries.
            if name == "." || name == ".." { return try next() }
            return .entry(makeEntry(name: name, body: body))
        default:
            throw .protocolError("unexpected sync id \(id.debugDescription)")
        }
    }

    private func makeEntry(name: String, body: Int) -> RemoteFile {
        let path = RemotePath.join(directory, name)
        if v2 {
            // error u32, dev u64, ino u64, mode u32, nlink u32, uid u32, gid u32, size u64, atime i64, mtime i64, ctime i64, namelen u32
            let error = buffer.u32(at: body)
            let mtime = buffer.i64(at: body + 52)
            return RemoteFile(
                name: name, path: path, mode: buffer.u32(at: body + 20), size: buffer.u64(at: body + 36),
                modificationDate: error == 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil, errorCode: error
            )
        }
        // mode u32, size u32, mtime u32, namelen u32
        return RemoteFile(
            name: name, path: path, mode: buffer.u32(at: body), size: UInt64(buffer.u32(at: body + 4)),
            modificationDate: Date(timeIntervalSince1970: TimeInterval(buffer.u32(at: body + 8)))
        )
    }
}

/// Incremental decoder for a `RECV` reply: `DATA` chunks, then `DONE`, or `FAIL` with a message.
public struct SyncRecvDecoder: Sendable {
    /// Decoded unit of a `RECV` reply.
    public enum Item: Sendable, Equatable {
        case data(Data)
        case done
    }

    private var buffer: [UInt8] = []
    private var offset = 0

    /// Creates an empty decoder.
    public init() {}

    /// Appends received bytes.
    public mutating func append(_ data: Data) {
        if offset > 0, offset >= buffer.count / 2 {
            buffer.removeFirst(offset)
            offset = 0
        }
        buffer.append(contentsOf: data)
    }

    /// Decodes the next item, or returns nil when more bytes are needed.
    /// - Throws: `AdbError.serverFailure` on `FAIL`, `.protocolError` on unexpected bytes.
    public mutating func next() throws(AdbError) -> Item? {
        let available = buffer.count - offset
        guard available >= 8 else { return nil }
        let id = String(decoding: buffer[offset..<offset + 4], as: UTF8.self)
        let length = Int(buffer.u32(at: offset + 4))
        switch id {
        case "DATA":
            guard length <= SyncProtocol.maxDataChunk else { throw .protocolError("DATA chunk of \(length) bytes") }
            guard available >= 8 + length else { return nil }
            let chunk = Data(buffer[offset + 8..<offset + 8 + length])
            offset += 8 + length
            return .data(chunk)
        case "DONE":
            offset += 8
            return .done
        case "FAIL":
            guard available >= 8 + length else { return nil }
            let message = String(decoding: buffer[offset + 8..<offset + 8 + length], as: UTF8.self)
            offset += 8 + length
            throw .serverFailure(message)
        default:
            throw .protocolError("unexpected sync id \(id.debugDescription)")
        }
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func u32(at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[index + $1]) << (8 * UInt32($1)) }
    }

    func u64(at index: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[index + $1]) << (8 * UInt64($1)) }
    }

    func i64(at index: Int) -> Int64 {
        Int64(bitPattern: u64(at: index))
    }
}
