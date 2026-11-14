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
}
