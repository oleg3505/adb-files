import Foundation
import Testing
@testable import AdbKit

private func makeOps(_ fs: FakeFileSystem) async throws -> (AdbFileOperations, FakeAdbServer) {
    let (client, server) = try await makeClient(FakeDevice(fs: fs))
    let host = AdbHostClient(host: "127.0.0.1", port: server.port, connectTimeout: .seconds(1), requestTimeout: .seconds(1))
    return (AdbFileOperations(serial: "FAKE", client: client, host: host), server)
}

private let marker = " 2>&1 && echo __ADBFILES_OK || echo __ADBFILES_FAIL"

@Suite("File operations against a fake file system")
struct AdbFileOperationsTests {
    @Test func renameQuotesAndUsesDoubleDash() async throws {
        let fs = FakeFileSystem(files: ["/d/a.txt": Data("x".utf8)])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        let newPath = try await ops.rename("/d/a.txt", to: "b c'.txt")
        #expect(newPath == "/d/b c'.txt")
        #expect(fs.commands.contains("mv -n -T -- '/d/a.txt' '/d/b c'\\''.txt'" + marker))
        #expect(fs.paths.contains("/d/b c'.txt") && !fs.paths.contains("/d/a.txt"))
    }

    @Test(arguments: ["-rf", "Звіт 🎉", "line\nbreak", "$(id)"])
    func renameHandlesHostileNames(name: String) async throws {
        let fs = FakeFileSystem(files: ["/d/a": Data()])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        try await ops.rename("/d/a", to: name)
        #expect(fs.paths.contains("/d/\(name)"))
        #expect(fs.commands.last?.contains("-- '/d/a' ") == true)
    }

    @Test func renameClashIsCaseInsensitiveAndSendsNothing() async throws {
        let fs = FakeFileSystem(caseInsensitive: true, files: ["/d/a.txt": Data(), "/d/B.txt": Data()])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        await #expect(throws: AdbError.alreadyExists("/d/b.txt")) { try await ops.rename("/d/a.txt", to: "b.txt") }
        #expect(!fs.commands.contains { $0.hasPrefix("mv") })
    }

    @Test func caseOnlyRenameGoesThroughATempName() async throws {
        let fs = FakeFileSystem(caseInsensitive: true, files: ["/d/a.txt": Data("x".utf8)])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        try await ops.rename("/d/a.txt", to: "A.txt")
        #expect(fs.paths.contains("/d/A.txt"))
        #expect(!fs.paths.contains("/d/a.txt"))
        let moves = fs.commands.filter { $0.hasPrefix("mv -T --") }
        #expect(moves.count == 2)
        #expect(moves[0].contains("/d/.adbfiles-rename-"))
    }

    @Test func failedSecondStepOfCaseRenameRollsBack() async throws {
        let fs = FakeFileSystem(caseInsensitive: true, files: ["/d/a.txt": Data()])
        fs.denyWrites(to: ["/d/A.txt"])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        await #expect(throws: AdbError.self) { try await ops.rename("/d/a.txt", to: "A.txt") }
        #expect(fs.paths.contains("/d/a.txt"), "rolled back to the original name")
        #expect(!fs.paths.contains { $0.contains(".adbfiles-rename-") })
    }

    @Test func silentNoOpIsDetected() async throws {
        let fs = FakeFileSystem(files: ["/d/a.txt": Data()])
        fs.ignoreAllCommands()
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        await #expect(throws: AdbError.operationFailed("The device did not rename “a.txt”.")) {
            try await ops.rename("/d/a.txt", to: "b.txt")
        }
    }

    @Test func missingSourceIsNotFound() async throws {
        let (ops, server) = try await makeOps(FakeFileSystem(directories: ["/d"]))
        defer { server.stop() }
        await #expect(throws: AdbError.notFound("/d/gone")) { try await ops.rename("/d/gone", to: "x") }
    }

    @Test func deviceErrorMessageIsReported() async throws {
        let fs = FakeFileSystem(files: ["/d/a": Data()])
        fs.denyWrites(to: ["/d"])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        await #expect(throws: AdbError.operationFailed("mv: /d/a: Permission denied")) { try await ops.rename("/d/a", to: "b") }
    }

    @Test func moveReportsPerItemResults() async throws {
        let fs = FakeFileSystem(caseInsensitive: true, directories: ["/dst"], files: ["/src/a": Data(), "/src/b": Data(), "/src/c": Data(), "/dst/B": Data()])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        let results = await ops.move(["/src/a", "/src/b", "/src/c"], into: "/dst")
        #expect(results["/src/a"] == .success("/dst/a"))
        #expect(results["/src/c"] == .success("/dst/c"))
        #expect(results["/src/b"] == .failure(.alreadyExists("/dst/b")))
        #expect(fs.paths.isSuperset(of: ["/dst/a", "/dst/c", "/src/b"]))
        #expect(fs.node(at: "/dst/B") != nil, "the existing file is untouched")
    }

    @Test func moveIntoItselfOrDescendantIsRefusedButSiblingPrefixIsFine() async throws {
        let fs = FakeFileSystem(directories: ["/a/b/c", "/a/bc"])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        let intoChild = await ops.move(["/a/b"], into: "/a/b/c")
        let intoSelf = await ops.move(["/a/b"], into: "/a/b")
        #expect(intoChild["/a/b"].map { if case .failure = $0 { true } else { false } } == true)
        #expect(intoSelf["/a/b"].map { if case .failure = $0 { true } else { false } } == true)
        #expect(!fs.commands.contains { $0.hasPrefix("mv") })
        let sibling = await ops.move(["/a/b"], into: "/a/bc")
        #expect(sibling["/a/b"] == .success("/a/bc/b"))
    }

    @Test func copyKeepsTheSource() async throws {
        let fs = FakeFileSystem(directories: ["/dst"], files: ["/src/f": Data("x".utf8)])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        let results = await ops.copy(["/src/f"], into: "/dst")
        #expect(results["/src/f"] == .success("/dst/f"))
        #expect(fs.paths.isSuperset(of: ["/src/f", "/dst/f"]))
        #expect(fs.commands.contains("cp -a -n -T -- '/src/f' '/dst/f'" + marker))
    }

    @Test func deleteReportsPerItemAndBatchesLongLists() async throws {
        var files: [String: Data] = [:]
        for index in 0..<400 { files["/d/\(String(repeating: "x", count: 30))\(index)"] = Data() }
        files["/locked/f"] = Data()
        let fs = FakeFileSystem(files: files)
        fs.denyWrites(to: ["/locked"])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        let paths = Array(files.keys)
        let results = await ops.delete(paths)
        #expect(results.values.filter { if case .success = $0 { true } else { false } }.count == 400)
        #expect(results["/locked/f"].map { if case .failure = $0 { true } else { false } } == true)
        #expect(fs.commands.filter { $0.hasPrefix("rm -r --") }.count > 1, "batched")
    }

    @Test func makeDirectoryRefusesCaseInsensitiveClash() async throws {
        let fs = FakeFileSystem(caseInsensitive: true, directories: ["/d/Untitled Folder"])
        let (ops, server) = try await makeOps(fs)
        defer { server.stop() }
        await #expect(throws: AdbError.alreadyExists("/d/untitled folder")) { try await ops.makeDirectory("/d/untitled folder") }
        try await ops.makeDirectory("/d/untitled folder 2")
        #expect(fs.node(at: "/d/untitled folder 2")?.isDirectory == true)
        #expect(fs.commands.contains("mkdir -- '/d/untitled folder 2'" + marker))
    }
}

@Suite("Checked shell output")
struct CheckedShellTests {
    @Test func onlyTheLastLineCounts() {
        func failure(_ output: String) -> AdbError? {
            if case .failure(let error) = AdbShell.parseChecked(output) { return error }
            return nil
        }
        #expect(failure("__ADBFILES_OK\n") == nil)
        #expect(failure("rm: /d/__ADBFILES_OK: Permission denied\n__ADBFILES_FAIL\n")
            == .operationFailed("rm: /d/__ADBFILES_OK: Permission denied"))
        #expect(failure("__ADBFILES_FAIL\n") == .operationFailed("The device reported an error."))
        if case .failure(.protocolError) = AdbShell.parseChecked("garbage") {} else { Issue.record("expected protocolError") }
    }
}
