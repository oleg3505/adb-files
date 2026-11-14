import Foundation
import os

/// Locates the `adb` executable and starts the ADB server with it.
///
/// The binary is used only for `adb start-server`; everything else talks to the server over TCP.
public struct AdbServerLauncher: Sendable {
    /// Environment variable that overrides the lookup with an explicit path (debugging aid).
    public static let overrideVariable = "ADBFILES_ADB_PATH"

    private let environment: [String: String]
    private let isExecutable: @Sendable (String) -> Bool

    /// Creates a launcher. The parameters exist for tests; the defaults use the real process environment
    /// and file system.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.environment = environment
        self.isExecutable = isExecutable
    }

    /// Paths checked in order: Homebrew (Apple silicon), Homebrew (Intel), Android SDK, then each `PATH` entry.
    public var candidatePaths: [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let fixed = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
        ]
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { !$0.isEmpty }
            .map { "\($0)/adb" }
        var seen = Set<String>()
        return (fixed + fromPath).filter { seen.insert($0).inserted }
    }

    /// Returns the `adb` executable to use.
    /// - Throws: `AdbError.adbNotFound` when nothing executable is found, or the override points nowhere.
    public func locateAdb() throws(AdbError) -> URL {
        if let override = environment[Self.overrideVariable], !override.isEmpty {
            guard isExecutable(override) else { throw .adbNotFound }
            return URL(fileURLWithPath: override)
        }
        guard let path = candidatePaths.first(where: isExecutable) else { throw .adbNotFound }
        return URL(fileURLWithPath: path)
    }

    /// Runs `adb start-server` and waits for it to finish, without blocking the calling thread.
    /// - Returns: The executable that was used.
    /// - Throws: `AdbError.adbNotFound`, `.serverStartFailed(output)` or `.timeout`.
    @discardableResult
    public func startServer(timeout: Duration = .seconds(15)) async throws -> URL {
        let adb = try locateAdb()
        Logger.adb.info("start-server via \(adb.path, privacy: .public)")
        let (status, output) = try await withTimeout(timeout) { try await Self.run(adb, arguments: ["start-server"]) }
        guard status == 0 else {
            Logger.adb.error("start-server failed (\(status)): \(output, privacy: .public)")
            throw AdbError.serverStartFailed(output.isEmpty ? "exit status \(status)" : output)
        }
        return adb
    }

    private static func run(_ executable: URL, arguments: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, String), Error>) in
                process.terminationHandler = { finished in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: (finished.terminationStatus, output))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: AdbError.serverStartFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}
