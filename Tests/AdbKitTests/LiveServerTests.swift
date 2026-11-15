import Foundation
import Testing
@testable import AdbKit

/// Talks to the real ADB server on 127.0.0.1:5037. Run with `ADB_TEST_SERVER=1 swift test`.
@Suite(
    "Live ADB server",
    .enabled(if: ProcessInfo.processInfo.environment["ADB_TEST_SERVER"] == "1")
)
struct LiveServerTests {
    @Test func versionIsReported() async throws {
        let version = try await AdbHostClient().version()
        #expect(version > 0)
    }

    @Test func devicesMatchesTrackFirstUpdate() async throws {
        let client = AdbHostClient()
        let listed = try await client.devices()
        var iterator = client.trackDevices().makeAsyncIterator()
        let tracked = try #require(try await iterator.next())
        #expect(Set(listed.map(\.serial)) == Set(tracked.map(\.serial)))
    }

    @Test func connectAndDisconnectReportAdbsMessages() async throws {
        // Port 1 is never listening: adb answers OKAY + a failure text, which must surface as an error.
        let client = AdbHostClient()
        await #expect(throws: AdbError.self) { try await client.connect(address: "127.0.0.1:1") }
        do {
            _ = try await client.connect(address: "127.0.0.1:1")
        } catch AdbError.serverFailure(let message) {
            #expect(message.contains("failed to connect"))
        }
        await #expect(throws: AdbError.serverFailure("no such device '127.0.0.1:1'")) {
            try await client.disconnect(address: "127.0.0.1:1")
        }
    }
}
