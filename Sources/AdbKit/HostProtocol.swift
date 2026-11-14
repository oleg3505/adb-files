import Foundation

/// Encoding for ADB host-protocol requests.
///
/// A request is the payload length as 4 lowercase hex digits followed by the UTF-8 payload,
/// e.g. `000chost:version` (AOSP `SERVICES.TXT`).
public enum HostProtocol {
    /// Encodes a service request such as `host:devices-l`.
    /// - Throws: `AdbError.invalidRequest` if the UTF-8 payload exceeds 65535 bytes.
    public static func encodeRequest(_ service: String) throws(AdbError) -> Data {
        let payload = Data(service.utf8)
        guard payload.count <= 0xFFFF else {
            throw .invalidRequest("request is \(payload.count) bytes, maximum is 65535")
        }
        var data = Data(String(format: "%04x", payload.count).utf8)
        data.append(payload)
        return data
    }
}

/// Status word that starts every host-protocol response.
public enum HostStatus: Sendable, Equatable {
    case okay
    case fail(String)
}

/// Incremental decoder for host-protocol responses.
///
/// Feed it bytes as they arrive with `append(_:)`, then ask for the next message. Methods return nil
/// when more bytes are needed and never consume a partial message.
public struct HostMessageDecoder: Sendable {
    private var buffer: [UInt8] = []

    /// Creates an empty decoder.
    public init() {}

    /// Number of buffered bytes not yet decoded.
    public var bufferedCount: Int { buffer.count }

    /// Appends received bytes.
    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Decodes `OKAY`, or `FAIL` followed by a hex-length-prefixed message.
    public mutating func decodeStatus() throws(AdbError) -> HostStatus? {
        guard buffer.count >= 4 else { return nil }
        let word = String(decoding: buffer[0..<4], as: UTF8.self)
        switch word {
        case "OKAY":
            buffer.removeFirst(4)
            return .okay
        case "FAIL":
            guard let message = try peekLengthPrefixed(at: 4) else { return nil }
            buffer.removeFirst(4 + 4 + message.count)
            return .fail(String(decoding: message, as: UTF8.self))
        default:
            throw .protocolError("expected OKAY or FAIL, got \(word.debugDescription)")
        }
    }

    /// Removes and returns every buffered byte.
    public mutating func drain() -> Data {
        defer { buffer.removeAll(keepingCapacity: true) }
        return Data(buffer)
    }

    /// Removes and returns exactly `count` bytes, or nil if fewer are buffered.
    public mutating func take(_ count: Int) -> Data? {
        guard buffer.count >= count else { return nil }
        defer { buffer.removeFirst(count) }
        return Data(buffer[0..<count])
    }

    /// Decodes one payload prefixed by its length as 4 hex digits.
    public mutating func decodeLengthPrefixed() throws(AdbError) -> Data? {
        guard let payload = try peekLengthPrefixed(at: 0) else { return nil }
        buffer.removeFirst(4 + payload.count)
        return Data(payload)
    }

    private func peekLengthPrefixed(at offset: Int) throws(AdbError) -> ArraySlice<UInt8>? {
        guard buffer.count >= offset + 4 else { return nil }
        let hex = String(decoding: buffer[offset..<offset + 4], as: UTF8.self)
        guard hex.allSatisfy(\.isHexDigit), let length = Int(hex, radix: 16) else {
            throw .protocolError("invalid length prefix \(hex.debugDescription)")
        }
        let start = offset + 4
        guard buffer.count >= start + length else { return nil }
        return buffer[start..<start + length]
    }
}
