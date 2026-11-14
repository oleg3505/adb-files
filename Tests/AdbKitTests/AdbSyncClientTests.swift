import Foundation
import os
import Testing
@testable import AdbKit

/// Scripted device behind `FakeAdbServer`: answers features, sync LIST/LIS2/LST2 and the access-check shell.
struct FakeDevice: Sendable {
    var features = "ls_v2,stat_v2"
    /// Directory (normalized) → entry names; missing key = empty listing.
    var listings: [String: [String]] = [:]
    /// Path (as requested) → errno for LST2; missing key = directory, no error.
    var statErrors: [String: UInt32] = [:]
    /// Reply of the access-check shell command.
    var shellReply = "ok\n"
    /// Send each listing reply in pieces of this many bytes.
    var chunkSize = Int.max
    /// After this many sync requests on one connection, close it (simulates a dropped connection).
    var closeAfterRequests = Int.max
    /// Never answer sync requests (simulates a hung device).
    var silent = false

    /// Records every request: "features", "shell:<cmd>", "sync-connection", "LIS2 <path>", …
    let log = OSAllocatedUnfairLock(initialState: [String]())

    func handle(_ client: FakeAdbServer.Client) async throws {
        let first = try await client.readRequest()
        if first.hasSuffix(":features") {
            log.withLock { $0.append("features") }
            try await client.write("OKAY")
            try await client.writeFramed(features)
            return
        }
        guard first.hasPrefix("host:transport:") else { return }
        try await client.write("OKAY")
        let service = try await client.readRequest()
        try await client.write("OKAY")
        if service.hasPrefix("shell:") {
            log.withLock { $0.append(service) }
            try await client.write(shellReply)
            client.close()
            return
        }
        log.withLock { $0.append("sync-connection") }
        var served = 0
        while true {
            let (id, path) = try await client.readSyncRequest()
            log.withLock { $0.append("\(id) \(path)") }
            if silent { try await Task.sleep(for: .seconds(30)) }
            switch id {
            case "LIS2", "LIST":
                let v2 = id == "LIS2"
                var reply = Data()
                for name in listings[RemotePath.normalized(path)] ?? [] {
                    reply += v2 ? Self.dnt2(name) : Self.dent(name)
                }
                reply += Data("DONE".utf8) + Data(count: v2 ? 72 : 16)
                var index = reply.startIndex
                while index < reply.endIndex {
                    let end = reply.index(index, offsetBy: min(chunkSize, reply.endIndex - index))
                    try await client.write(Data(reply[index..<end]))
                    index = end
                }
            case "LST2":
                var reply = Data("LST2".utf8)
                let error = statErrors[path] ?? 0
                reply += Self.le(error) + Data(count: 16) + Self.le(UInt32(error == 0 ? 0o40770 : 0)) + Data(count: 48)
                try await client.write(reply)
            default:
                return
            }
            served += 1
            if served >= closeAfterRequests {
                client.close()
                return
            }
        }
    }

    static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func dnt2(_ name: String) -> Data {
        let nameBytes = Data(name.utf8)
        var data = Data("DNT2".utf8)
        data.append(le(UInt32(0)))               // error
        data.append(Data(count: 16))             // dev, ino
        data.append(le(UInt32(0o100660)))        // mode
        data.append(Data(count: 12))             // nlink, uid, gid
        data.append(le(UInt64(42)))              // size
        data.append(Data(count: 8))              // atime
        data.append(le(Int64(1_700_000_000)))    // mtime
        data.append(Data(count: 8))              // ctime
        data.append(le(UInt32(nameBytes.count))) // namelen
        data.append(nameBytes)
        return data
    }

    static func dent(_ name: String) -> Data {
        let nameBytes = Data(name.utf8)
        var data = Data("DENT".utf8)
        data.append(le(UInt32(0o100660)))
        data.append(le(UInt32(42)))
        data.append(le(UInt32(1_700_000_000)))
        data.append(le(UInt32(nameBytes.count)))
        data.append(nameBytes)
        return data
    }
}

private func makeClient(_ device: FakeDevice, listTimeout: Duration = .seconds(2)) async throws -> (AdbSyncClient, FakeAdbServer) {
    let server = try await FakeAdbServer.start { try await device.handle($0) }
    let host = AdbHostClient(host: "127.0.0.1", port: server.port, connectTimeout: .seconds(1), requestTimeout: .seconds(1))
    return (AdbSyncClient(serial: "FAKE", host: host, listTimeout: listTimeout), server)
}

@Suite("AdbSyncClient against a fake device")
struct AdbSyncClientTests {
    @Test func listsWithLIS2() async throws {
        let device = FakeDevice(listings: ["/sdcard": ["DCIM", "Download", "a.txt"]])
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        let entries = try await client.list("/sdcard")
        #expect(entries.map(\.path) == ["/sdcard/DCIM", "/sdcard/Download", "/sdcard/a.txt"])
        #expect(entries.allSatisfy { $0.size == 42 })
        #expect(device.log.withLock { $0 }.contains("LIS2 /sdcard/"))
    }

    @Test func fallsBackToLISTWithoutFeature() async throws {
        let device = FakeDevice(features: "shell_v2", listings: ["/sdcard": ["x"]])
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        #expect(try await client.list("/sdcard").map(\.name) == ["x"])
        #expect(device.log.withLock { $0 }.contains("LIST /sdcard/"))
    }

    @Test func handlesChunkedReplies() async throws {
        let names = (0..<200).map { "IMG_\($0).jpg" }
        let (client, server) = try await makeClient(FakeDevice(listings: ["/d": names], chunkSize: 7))
        defer { server.stop() }
        #expect(try await client.list("/d").count == 200)
    }

    @Test func emptyAndMissingIsNotFound() async throws {
        let device = FakeDevice(statErrors: ["/gone/": 2])
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        await #expect(throws: AdbError.notFound("/gone")) { try await client.list("/gone") }
        #expect(!device.log.withLock { $0 }.contains { $0.hasPrefix("shell:") }, "no shell call when stat already answers")
    }

    @Test func emptyAndDeniedUsesExactShellCommand() async throws {
        let device = FakeDevice(shellReply: "denied\n")
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        await #expect(throws: AdbError.permissionDenied("/data")) { try await client.list("/data") }
        #expect(device.log.withLock { $0 }.contains("shell:test -r '/data' -a -x '/data' && echo ok || echo denied"))
    }

    @Test func emptyAndReadableIsEmpty() async throws {
        let (client, server) = try await makeClient(FakeDevice(shellReply: "ok\n"))
        defer { server.stop() }
        #expect(try await client.list("/sdcard/Empty").isEmpty)
    }

    @Test func reconnectsAfterConnectionDrops() async throws {
        let device = FakeDevice(listings: ["/a": ["1"], "/b": ["2"]], closeAfterRequests: 1)
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        #expect(try await client.list("/a").map(\.name) == ["1"])
        // The first connection is closed by the device; the next call may fail once, then must reconnect.
        let second = try? await client.list("/b")
        let third = try await client.list("/b")
        #expect(second == nil || second?.map(\.name) == ["2"])
        #expect(third.map(\.name) == ["2"])
        #expect(device.log.withLock { $0 }.filter { $0 == "sync-connection" }.count >= 2)
    }

    @Test func silentDeviceTimesOut() async throws {
        let (client, server) = try await makeClient(FakeDevice(silent: true), listTimeout: .milliseconds(300))
        defer { server.stop() }
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: AdbError.timeout) { try await client.list("/x") }
        #expect(clock.now - started < .seconds(2))
    }

    @Test func disconnectEndsListingPromptly() async throws {
        let (client, server) = try await makeClient(FakeDevice(silent: true), listTimeout: .seconds(10))
        defer { server.stop() }
        let listing = Task { try await client.list("/x") }
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let started = clock.now
        await client.disconnect()
        await #expect(throws: (any Error).self) { try await listing.value }
        #expect(clock.now - started < .seconds(1))
    }

    @Test func cancellingCallerEndsListingPromptly() async throws {
        let (client, server) = try await makeClient(FakeDevice(silent: true), listTimeout: .seconds(10))
        defer { server.stop() }
        let listing = Task { try await client.list("/x") }
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let started = clock.now
        listing.cancel()
        await #expect(throws: (any Error).self) { try await listing.value }
        #expect(clock.now - started < .seconds(1))
    }

    @Test func concurrentCallsAreSerialized() async throws {
        let device = FakeDevice(listings: ["/a": (0..<300).map { "a\($0)" }, "/b": (0..<300).map { "b\($0)" }], chunkSize: 50)
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        async let a = client.list("/a")
        async let b = client.list("/b")
        let (listA, listB) = try await (a, b)
        #expect(listA.count == 300 && listA.allSatisfy { $0.name.hasPrefix("a") })
        #expect(listB.count == 300 && listB.allSatisfy { $0.name.hasPrefix("b") })
    }

    @Test func rejectsOverlongPathWithoutSending() async throws {
        let device = FakeDevice()
        let (client, server) = try await makeClient(device)
        defer { server.stop() }
        await #expect(throws: AdbError.self) { try await client.list("/" + String(repeating: "x", count: 1100)) }
        #expect(!device.log.withLock { $0 }.contains { $0.hasPrefix("LIS2") })
    }
}
