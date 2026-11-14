import Foundation
import Testing
@testable import AdbKit

@Suite("adb lookup")
struct AdbServerLauncherTests {
    private func launcher(env: [String: String], existing: Set<String>) -> AdbServerLauncher {
        AdbServerLauncher(environment: env, isExecutable: { existing.contains($0) })
    }

    @Test func homebrewArmWinsOverEverything() throws {
        let sut = launcher(
            env: ["HOME": "/Users/me", "PATH": "/custom/bin"],
            existing: ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/custom/bin/adb"]
        )
        #expect(try sut.locateAdb().path == "/opt/homebrew/bin/adb")
    }

    @Test func fallsBackInDocumentedOrder() throws {
        let env = ["HOME": "/Users/me", "PATH": "/custom/bin"]
        #expect(try launcher(env: env, existing: ["/usr/local/bin/adb", "/custom/bin/adb"]).locateAdb().path
            == "/usr/local/bin/adb")
        #expect(try launcher(env: env, existing: ["/Users/me/Library/Android/sdk/platform-tools/adb", "/custom/bin/adb"])
            .locateAdb().path == "/Users/me/Library/Android/sdk/platform-tools/adb")
        #expect(try launcher(env: env, existing: ["/custom/bin/adb"]).locateAdb().path == "/custom/bin/adb")
    }

    @Test func pathEntriesAreSearchedInOrderWithoutDuplicates() {
        let sut = launcher(env: ["HOME": "/h", "PATH": "/a:/usr/local/bin::/b"], existing: [])
        #expect(sut.candidatePaths == [
            "/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/h/Library/Android/sdk/platform-tools/adb",
            "/a/adb", "/b/adb",
        ])
    }

    @Test func overrideWins() throws {
        let sut = launcher(
            env: ["ADBFILES_ADB_PATH": "/tmp/my-adb", "HOME": "/h"],
            existing: ["/tmp/my-adb", "/opt/homebrew/bin/adb"]
        )
        #expect(try sut.locateAdb().path == "/tmp/my-adb")
    }

    @Test func overrideToMissingFileMeansNotFound() {
        let sut = launcher(env: ["ADBFILES_ADB_PATH": "/nonexistent", "HOME": "/h"], existing: ["/opt/homebrew/bin/adb"])
        #expect(throws: AdbError.adbNotFound) { try sut.locateAdb() }
    }

    @Test func nothingFoundThrows() {
        let sut = launcher(env: ["HOME": "/h", "PATH": "/x"], existing: [])
        #expect(throws: AdbError.adbNotFound) { try sut.locateAdb() }
    }

    @Test func startServerWithoutAdbThrowsNotFound() async {
        let sut = launcher(env: ["ADBFILES_ADB_PATH": "/nonexistent"], existing: [])
        await #expect(throws: AdbError.adbNotFound) { try await sut.startServer() }
    }

    @Test func nonZeroExitIsServerStartFailedWithOutput() async throws {
        // `/bin/sh start-server` fails: sh tries to run a script named "start-server" that does not exist.
        let sut = AdbServerLauncher(environment: ["ADBFILES_ADB_PATH": "/bin/sh"])
        do {
            try await sut.startServer()
            Issue.record("expected failure")
        } catch AdbError.serverStartFailed(let output) {
            #expect(output.contains("start-server"))
        }
    }
}
