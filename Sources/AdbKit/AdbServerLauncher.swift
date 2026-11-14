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

    private enum RunState: Sendable { case notStarted, running, cancelled }

    private static func run(_ executable: URL, arguments: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let state = OSAllocatedUnfairLock(initialState: RunState.notStarted)
        let output = OSAllocatedUnfairLock(initialState: Data())
        let reader = pipe.fileHandleForReading
        // Drain output while the process runs. Reading to EOF after exit could block forever if a child
        // (the forked adb daemon) inherited the pipe and keeps it open.
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                output.withLock { $0.append(chunk) }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, String), Error>) in
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    // Give the readability handler a moment to deliver the last chunk.
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                        reader.readabilityHandler = nil
                        if state.withLock({ $0 == .cancelled }) {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let text = String(decoding: output.withLock { $0 }, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: (status, text))
                    }
                }
                let launch: Result<Void, Error>? = state.withLock { state in
                    guard state == .notStarted else { return nil } // cancelled before launch
                    do {
                        try process.run()
                        state = .running
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
                switch launch {
                case .success:
                    break
                case .failure(let error):
                    reader.readabilityHandler = nil
                    continuation.resume(throwing: AdbError.serverStartFailed(error.localizedDescription))
                case nil:
                    reader.readabilityHandler = nil
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            state.withLock { state in
                // Terminating a process that never launched raises an Objective-C exception.
                if state == .running { process.terminate() }
                state = .cancelled
            }
        }
    }
}
