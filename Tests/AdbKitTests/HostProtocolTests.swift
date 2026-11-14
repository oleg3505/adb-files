import Foundation
import Testing
@testable import AdbKit

@Suite("Host protocol framing")
struct HostProtocolTests {
    @Test func encodesRequestWithHexLength() throws {
        let data = try HostProtocol.encodeRequest("host:version")
        #expect(String(decoding: data, as: UTF8.self) == "000chost:version")
    }

    @Test func lengthCountsUTF8BytesNotCharacters() throws {
        // "Фото 📷" = 4 Cyrillic letters (2 bytes each) + space + emoji (4 bytes) = 13 bytes.
        let data = try HostProtocol.encodeRequest("Фото 📷")
        #expect(data.prefix(4) == Data("000d".utf8))
        #expect(data.count == 4 + 13)
    }

    @Test func rejectsOversizedRequest() {
        #expect(throws: AdbError.self) {
            try HostProtocol.encodeRequest(String(repeating: "a", count: 0x10000))
        }
    }

    @Test func decodesOkay() throws {
        var decoder = HostMessageDecoder()
        decoder.append(Data("OKAY".utf8))
        #expect(try decoder.decodeStatus() == .okay)
        #expect(decoder.bufferedCount == 0)
    }

    @Test func decodesFailWithMessage() throws {
        // Captured from adb 1.0.41 for `host:bogus`.
        var decoder = HostMessageDecoder()
        decoder.append(Data("FAIL001cunknown host service 'bogus'".utf8))
        #expect(try decoder.decodeStatus() == .fail("unknown host service 'bogus'"))
    }

    @Test func failWaitsForFullMessage() throws {
        var decoder = HostMessageDecoder()
        decoder.append(Data("FAIL001cunknown".utf8))
        #expect(try decoder.decodeStatus() == nil)
        decoder.append(Data(" host service 'bogus'".utf8))
        #expect(try decoder.decodeStatus() == .fail("unknown host service 'bogus'"))
    }

    @Test func statusNeedsFourBytes() throws {
        var decoder = HostMessageDecoder()
        decoder.append(Data("OK".utf8))
        #expect(try decoder.decodeStatus() == nil)
        decoder.append(Data("AY".utf8))
        #expect(try decoder.decodeStatus() == .okay)
    }

    @Test func rejectsUnknownStatusWord() {
        var decoder = HostMessageDecoder()
        decoder.append(Data("HELO".utf8))
        #expect(throws: AdbError.self) { try decoder.decodeStatus() }
    }

    @Test func decodesPayloadSplitAcrossChunks() throws {
        var decoder = HostMessageDecoder()
        decoder.append(Data("00".utf8))
        #expect(try decoder.decodeLengthPrefixed() == nil)
        decoder.append(Data("04002".utf8))
        #expect(try decoder.decodeLengthPrefixed() == nil)
        decoder.append(Data("9".utf8))
        #expect(try decoder.decodeLengthPrefixed() == Data("0029".utf8))
    }

    @Test func decodesTwoPayloadsInOneChunk() throws {
        var decoder = HostMessageDecoder()
        decoder.append(Data("0003abc0000".utf8))
        #expect(try decoder.decodeLengthPrefixed() == Data("abc".utf8))
        #expect(try decoder.decodeLengthPrefixed() == Data())
        #expect(try decoder.decodeLengthPrefixed() == nil)
    }

    @Test func rejectsInvalidHexLength() {
        var decoder = HostMessageDecoder()
        decoder.append(Data("00zzabc".utf8))
        #expect(throws: AdbError.self) { try decoder.decodeLengthPrefixed() }
    }

    @Test func decodesLiveVersionResponse() throws {
        // Captured: `host:version` on adb 1.0.41 → OKAY 0004 0029 (protocol version 0x29 = 41).
        var decoder = HostMessageDecoder()
        decoder.append(Data("OKAY00040029".utf8))
        #expect(try decoder.decodeStatus() == .okay)
        #expect(try decoder.decodeLengthPrefixed() == Data("0029".utf8))
    }
}
