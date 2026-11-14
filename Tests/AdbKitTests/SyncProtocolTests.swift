import Foundation
import Testing
@testable import AdbKit

private func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        if let byte = UInt8(string[index..<next], radix: 16) { data.append(byte) }
        index = next
    }
    return data
}

/// Builds a DNT2 entry the way adbd does (little-endian, packed).
private func dnt2(name: String, mode: UInt32, size: UInt64, mtime: Int64, error: UInt32 = 0) -> Data {
    var data = Data("DNT2".utf8)
    func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    put(error); put(UInt64(1)); put(UInt64(2)); put(mode); put(UInt32(1)); put(UInt32(0)); put(UInt32(0))
    put(size); put(mtime); put(mtime); put(mtime)
    let nameBytes = Data(name.utf8)
    put(UInt32(nameBytes.count))
    data.append(nameBytes)
    return data
}

private let doneV2 = Data("DONE".utf8) + Data(count: 72)
private let doneV1 = Data("DONE".utf8) + Data(count: 16)

@Suite("Sync protocol")
struct SyncProtocolTests {
    @Test func encodesRequestWithLittleEndianLength() throws {
        let data = try SyncProtocol.encodeRequest(.listV2, path: "/sdcard/")
        #expect(data == Data("LIS2".utf8) + Data([8, 0, 0, 0]) + Data("/sdcard/".utf8))
    }

    @Test func requestLengthCountsUTF8Bytes() throws {
        let data = try SyncProtocol.encodeRequest(.list, path: "/sdcard/Фото")
        #expect(data[4..<8] == Data([16, 0, 0, 0])) // 8 ASCII + 4 Cyrillic × 2 bytes
    }

    @Test func rejectsPathOver1024Bytes() {
        #expect(throws: AdbError.self) {
            try SyncProtocol.encodeRequest(.listV2, path: "/" + String(repeating: "a", count: 1024))
        }
    }

    @Test func decodesLiveDNT2Capture() throws {
        // First DNT2 entry of `LIS2 /sdcard/` captured from a Pixel 4 (Android 13).
        let live = hex(
            "444e5432000000009800000000000000ad0b000000000000f841000005000000000000000d270000"
                + "a00d0000000000001019176100000000101917610000000010191761000000000700000041" + "6e64726f6964"
        )
        var decoder = SyncListDecoder(v2: true, directory: "/sdcard/")
        decoder.append(live)
        let item = try decoder.next()
        let expected = RemoteFile(
            name: "Android", path: "/sdcard/Android", mode: 0o40770, size: 3488,
            modificationDate: Date(timeIntervalSince1970: 1_628_903_696)
        )
        #expect(item == .entry(expected))
        #expect(expected.isDirectory)
        #expect(try decoder.next() == nil)
    }

    @Test func decodesStreamSplitIntoTinyChunks() throws {
        let stream = dnt2(name: "a.jpg", mode: 0o100660, size: 10, mtime: 1)
            + dnt2(name: "b", mode: 0o40770, size: 0, mtime: 2) + doneV2
        var decoder = SyncListDecoder(v2: true, directory: "/x")
        var items: [SyncListDecoder.Item] = []
        for byte in stream {
            decoder.append(Data([byte]))
            while let item = try decoder.next() { items.append(item) }
        }
        #expect(items.count == 3)
        #expect(items.last == .done)
        if case .entry(let file) = items[0] { #expect(file.path == "/x/a.jpg") }
    }

    @Test func decodesManyEntriesInOneChunk() throws {
        var stream = Data()
        for index in 0..<10_000 { stream += dnt2(name: "IMG_\(index).jpg", mode: 0o100660, size: UInt64(index), mtime: 0) }
        stream += doneV2
        var decoder = SyncListDecoder(v2: true, directory: "/sdcard/DCIM/Camera")
        decoder.append(stream)
        var count = 0
        while let item = try decoder.next() {
            if case .entry = item { count += 1 }
        }
        #expect(count == 10_000)
    }

    @Test func decodesCyrillicAndEmojiNames() throws {
        var decoder = SyncListDecoder(v2: true, directory: "/sdcard/Download")
        decoder.append(dnt2(name: "Звіт 2024 📄.pdf", mode: 0o100660, size: 1, mtime: 0) + doneV2)
        guard case .entry(let file)? = try decoder.next() else {
            Issue.record("expected an entry")
            return
        }
        #expect(file.name == "Звіт 2024 📄.pdf")
        #expect(file.path == "/sdcard/Download/Звіт 2024 📄.pdf")
    }

    @Test func keepsSizesAbove4GiB() throws {
        var decoder = SyncListDecoder(v2: true, directory: "/sdcard/Movies")
        decoder.append(dnt2(name: "big.mkv", mode: 0o100660, size: 5_368_709_120, mtime: 0))
        guard case .entry(let file)? = try decoder.next() else {
            Issue.record("expected an entry")
            return
        }
        #expect(file.size == 5_368_709_120)
    }

    @Test func entryWithErrorHasNoDate() throws {
        var decoder = SyncListDecoder(v2: true, directory: "/proc")
        decoder.append(dnt2(name: "ghost", mode: 0, size: 0, mtime: 0, error: 13))
        guard case .entry(let file)? = try decoder.next() else {
            Issue.record("expected an entry")
            return
        }
        #expect(file.hasError)
        #expect(file.errorCode == 13)
        #expect(file.modificationDate == nil)
    }

    @Test func decodesV1Dent() throws {
        var dent = Data("DENT".utf8)
        for value: UInt32 in [0o100644, 1234, 1_700_000_000, 5] {
            withUnsafeBytes(of: value.littleEndian) { dent.append(contentsOf: $0) }
        }
        dent += Data("x.txt".utf8)
        var decoder = SyncListDecoder(v2: false, directory: "/")
        decoder.append(dent + doneV1)
        #expect(try decoder.next() == .entry(RemoteFile(
            name: "x.txt", path: "/x.txt", mode: 0o100644, size: 1234,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )))
        #expect(try decoder.next() == .done)
    }

    @Test func failCarriesMessage() {
        var decoder = SyncListDecoder(v2: true, directory: "/")
        decoder.append(Data("FAIL".utf8) + Data([13, 0, 0, 0]) + Data("path too long".utf8))
        #expect(throws: AdbError.serverFailure("path too long")) { try decoder.next() }
    }

    @Test func rejectsUnexpectedId() {
        var decoder = SyncListDecoder(v2: true, directory: "/")
        decoder.append(Data("DENT".utf8) + Data(count: 16)) // v1 entry in a v2 stream
        #expect(throws: AdbError.self) { try decoder.next() }
    }

    @Test func decodesLst2Reply() throws {
        var reply = Data("LST2".utf8)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { reply.append(contentsOf: $0) } }
        put(UInt32(0)); put(UInt64(0)); put(UInt64(0)); put(UInt32(0o40771)); put(UInt32(0)); put(UInt32(0)); put(UInt32(0))
        put(UInt64(4096)); put(Int64(0)); put(Int64(1_600_000_000)); put(Int64(0))
        let stat = try SyncProtocol.decodeStat(reply, v2: true)
        #expect(stat == SyncStat(errorCode: 0, mode: 0o40771, size: 4096, mtime: 1_600_000_000))
        #expect(stat.isDirectory)
    }

    @Test func decodesMissingPathLst2() throws {
        var reply = Data("LST2".utf8)
        withUnsafeBytes(of: UInt32(2).littleEndian) { reply.append(contentsOf: $0) }
        reply += Data(count: 64)
        #expect(try SyncProtocol.decodeStat(reply, v2: true).errorCode == 2)
    }
}

@Suite("Remote paths and files")
struct RemotePathTests {
    @Test func joinsAndNormalizes() {
        #expect(RemotePath.join("/", "sdcard") == "/sdcard")
        #expect(RemotePath.join("/sdcard/", "DCIM") == "/sdcard/DCIM")
        #expect(RemotePath.normalized("/sdcard///") == "/sdcard")
        #expect(RemotePath.normalized("/") == "/")
    }

    @Test func listingPathAlwaysEndsWithSlash() {
        #expect(RemotePath.listingPath("/sdcard") == "/sdcard/")
        #expect(RemotePath.listingPath("/") == "/")
    }

    @Test func parentAndComponents() {
        #expect(RemotePath.parent(of: "/sdcard/DCIM") == "/sdcard")
        #expect(RemotePath.parent(of: "/sdcard") == "/")
        #expect(RemotePath.parent(of: "/") == nil)
        #expect(RemotePath.components("/sdcard/DCIM/Camera") == ["sdcard", "DCIM", "Camera"])
        #expect(RemotePath.components("/").isEmpty)
    }

    @Test func fileKindsFromMode() {
        let link = RemoteFile(name: "sdcard", path: "/sdcard", mode: 0o120777, size: 21, modificationDate: nil)
        #expect(link.isSymlink && !link.isDirectory)
        #expect(RemoteFile(name: ".nomedia", path: "/x/.nomedia", mode: 0o100660, size: 0, modificationDate: nil).isHidden)
    }
}
