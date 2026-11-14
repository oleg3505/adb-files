import Foundation
import Testing
@testable import AdbKit

private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

@Suite("Sync transfer framing")
struct SyncTransferProtocolTests {
    @Test func sendRequestUsesDecimalMode() throws {
        let data = try SyncProtocol.encodeSendRequest(path: "/sdcard/a b.txt", mode: 0o644)
        let spec = "/sdcard/a b.txt,420"
        #expect(data == Data("SEND".utf8) + le32(UInt32(spec.utf8.count)) + Data(spec.utf8))
    }

    @Test func sendRequestCountsUTF8Bytes() throws {
        let data = try SyncProtocol.encodeSendRequest(path: "/sdcard/Привіт 🎉.txt", mode: 0o644)
        let spec = Data("/sdcard/Привіт 🎉.txt,420".utf8)
        #expect(data.subdata(in: 4..<8) == le32(UInt32(spec.count)))
    }

    @Test func sendRequestRejectsOverlongSpec() {
        #expect(throws: AdbError.self) {
            try SyncProtocol.encodeSendRequest(path: "/" + String(repeating: "x", count: 1020), mode: 0o644)
        }
    }

    @Test func dataAndDoneFraming() {
        #expect(SyncProtocol.encodeData(Data([1, 2, 3])) == Data("DATA".utf8) + le32(3) + Data([1, 2, 3]))
        #expect(SyncProtocol.encodeDone(mtime: 1_700_000_000) == Data("DONE".utf8) + le32(1_700_000_000))
    }

    @Test func statusHeader() throws {
        #expect(try SyncProtocol.parseStatusHeader(Data("OKAY".utf8) + le32(0)) == nil)
        #expect(try SyncProtocol.parseStatusHeader(Data("FAIL".utf8) + le32(43)) == 43)
        #expect(throws: AdbError.self) { try SyncProtocol.parseStatusHeader(Data("NOPE".utf8) + le32(0)) }
    }

    @Test func recvDecodesLiveFullChunkHeader() throws {
        // First RECV header captured from a Pixel 4 for a 26 MB file: DATA, 65,536 bytes.
        let header = Data([0x44, 0x41, 0x54, 0x41, 0x00, 0x00, 0x01, 0x00])
        var decoder = SyncRecvDecoder()
        decoder.append(header + Data(repeating: 7, count: 65_536) + Data("DONE".utf8) + le32(0))
        #expect(try decoder.next() == .data(Data(repeating: 7, count: 65_536)))
        #expect(try decoder.next() == .done)
        #expect(try decoder.next() == nil)
    }

    @Test func recvByteByByte() throws {
        let stream = Data("DATA".utf8) + le32(5) + Data("hello".utf8) + Data("DATA".utf8) + le32(1) + Data("!".utf8)
            + Data("DONE".utf8) + le32(0)
        var decoder = SyncRecvDecoder()
        var payload = Data()
        var finished = false
        for byte in stream {
            decoder.append(Data([byte]))
            while let item = try decoder.next() {
                switch item {
                case .data(let chunk): payload += chunk
                case .done: finished = true
                }
            }
        }
        #expect(payload == Data("hello!".utf8))
        #expect(finished)
    }

    @Test func recvFailCarriesLiveMessage() {
        let message = "open failed: No such file or directory"
        var decoder = SyncRecvDecoder()
        decoder.append(Data("FAIL".utf8) + le32(UInt32(message.utf8.count)) + Data(message.utf8))
        #expect(throws: AdbError.serverFailure(message)) { try decoder.next() }
    }

    @Test func recvRejectsOversizedChunk() {
        var decoder = SyncRecvDecoder()
        decoder.append(Data("DATA".utf8) + le32(70_000))
        #expect(throws: AdbError.self) { try decoder.next() }
    }

    @Test func recvRejectsUnknownId() {
        var decoder = SyncRecvDecoder()
        decoder.append(Data("DENT".utf8) + le32(0))
        #expect(throws: AdbError.self) { try decoder.next() }
    }
}
