import Foundation
import os
@testable import AdbKit

/// An in-memory device file system that executes the shell commands AdbKit sends (`mv`, `cp -a`, `rm -r`,
/// `mkdir`, `ls -a`) with toybox semantics, including `-n` skipping silently, and optionally case-insensitive
/// lookups like Android's FUSE shared storage.
final class FakeFileSystem: Sendable {
    struct Node: Sendable {
        var isDirectory: Bool
        var data = Data()
        var mtime: Int64 = 1_700_000_000
    }

    private struct State {
        var nodes: [String: Node] = ["/": Node(isDirectory: true)]
        var commands: [String] = []
        var failPaths: Set<String> = []
        var ignoreCommands = false
    }

    let caseInsensitive: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(caseInsensitive: Bool = false, directories: [String] = [], files: [String: Data] = [:]) {
        self.caseInsensitive = caseInsensitive
        state.withLock { state in
            for dir in directories { Self.makeParents(dir, in: &state.nodes); state.nodes[dir] = Node(isDirectory: true) }
            for (path, data) in files {
                Self.makeParents(path, in: &state.nodes)
                state.nodes[path] = Node(isDirectory: false, data: data)
            }
        }
    }

    /// Commands touching these paths fail with "Permission denied".
    func denyWrites(to paths: Set<String>) { state.withLock { $0.failPaths = paths } }
    /// Every command reports success but changes nothing (the silent `-n` trap).
    func ignoreAllCommands() { state.withLock { $0.ignoreCommands = true } }

    var commands: [String] { state.withLock { $0.commands } }
    /// Exact-case paths currently present.
    var paths: Set<String> { state.withLock { Set($0.nodes.keys) } }

    func node(at path: String) -> Node? {
        state.withLock { state in Self.resolve(path, in: state.nodes, caseInsensitive: caseInsensitive).map { state.nodes[$0]! } }
    }

    /// Children of a directory with their stored names (exact case).
    func children(of directory: String) -> [(name: String, node: Node)] {
        state.withLock { state in
            guard let dir = Self.resolve(directory, in: state.nodes, caseInsensitive: caseInsensitive) else { return [] }
            return state.nodes.filter { RemotePath.parent(of: $0.key) == dir && $0.key != "/" }
                .map { ((($0.key as NSString).lastPathComponent), $0.value) }
                .sorted { $0.name < $1.name }
        }
    }

    // MARK: - Shell

    /// Executes a command string as sent by AdbKit and returns its output.
    func handleShell(_ command: String) -> String {
        state.withLock { $0.commands.append(command) }
        if command.hasPrefix("ls -a ") {
            let path = Self.tokenize(command)[2]
            return node(at: path)?.isDirectory == true ? "ok\n" : "denied\n"
        }
        let marker = " 2>&1 && echo __ADBFILES_OK || echo __ADBFILES_FAIL"
        let mkdirMarker = " && echo ok || echo fail"
        if command.hasSuffix(mkdirMarker) {
            let tokens = Self.tokenize(String(command.dropLast(mkdirMarker.count)))
            for path in tokens.dropFirst(2) { create(path, parents: true) }
            return "ok\n"
        }
        guard command.hasSuffix(marker) else { return "unknown command\n" }
        let tokens = Self.tokenize(String(command.dropLast(marker.count)))
        let (output, ok) = execute(tokens)
        return output + (ok ? "__ADBFILES_OK\n" : "__ADBFILES_FAIL\n")
    }

    private func execute(_ tokens: [String]) -> (String, Bool) {
        guard let program = tokens.first, let dashes = tokens.firstIndex(of: "--") else { return ("bad command\n", false) }
        let flags = Set(tokens[1..<dashes])
        let args = Array(tokens[(dashes + 1)...])
        let (failPaths, ignore) = state.withLock { ($0.failPaths, $0.ignoreCommands) }
        if ignore { return ("", true) }
        let isDenied: @Sendable (String) -> Bool = { path in failPaths.contains { path == $0 || path.hasPrefix($0 + "/") } }
        // rm handles each path on its own (like toybox); other commands fail as a whole.
        if program != "rm", let denied = args.first(where: isDenied) {
            return ("\(program): \(denied): Permission denied\n", false)
        }
        switch program {
        case "mv", "cp":
            guard args.count == 2 else { return ("\(program): bad args\n", false) }
            return state.withLock { state in
                guard let source = Self.resolve(args[0], in: state.nodes, caseInsensitive: caseInsensitive) else {
                    return ("\(program): \(args[0]): No such file or directory\n", false)
                }
                if flags.contains("-n"), Self.resolve(args[1], in: state.nodes, caseInsensitive: caseInsensitive) != nil {
                    return ("", true) // toybox -n: skip silently, exit 0
                }
                let moved = state.nodes.filter { $0.key == source || $0.key.hasPrefix(source + "/") }
                if program == "mv" { for key in moved.keys { state.nodes[key] = nil } }
                for (key, node) in moved { state.nodes[args[1] + key.dropFirst(source.count)] = node }
                return ("", true)
            }
        case "rm":
            let output: String = state.withLock { state in
                var output = ""
                for path in args {
                    if isDenied(path) {
                        output += "rm: \(path): Permission denied\n"
                        continue
                    }
                    guard let target = Self.resolve(path, in: state.nodes, caseInsensitive: caseInsensitive) else {
                        output += "rm: \(path): No such file or directory\n"
                        continue
                    }
                    for key in state.nodes.keys where key == target || key.hasPrefix(target + "/") { state.nodes[key] = nil }
                }
                return output
            }
            return (output, output.isEmpty)
        case "mkdir":
            for path in args {
                if node(at: path) != nil { return ("mkdir: \(path): File exists\n", false) }
                guard let parent = RemotePath.parent(of: path), node(at: parent)?.isDirectory == true else {
                    return ("mkdir: \(path): No such file or directory\n", false)
                }
                create(path, parents: false)
            }
            return ("", true)
        default:
            return ("\(program): not found\n", false)
        }
    }

    private func create(_ path: String, parents: Bool) {
        state.withLock { state in
            if parents { Self.makeParents(path, in: &state.nodes) }
            if Self.resolve(path, in: state.nodes, caseInsensitive: caseInsensitive) == nil {
                state.nodes[path] = Node(isDirectory: true)
            }
        }
    }

    // MARK: - Helpers

    private static func makeParents(_ path: String, in nodes: inout [String: Node]) {
        var current = RemotePath.parent(of: path)
        while let dir = current, dir != "/" {
            if nodes[dir] == nil { nodes[dir] = Node(isDirectory: true) }
            current = RemotePath.parent(of: dir)
        }
    }

    private static func resolve(_ path: String, in nodes: [String: Node], caseInsensitive: Bool) -> String? {
        let normalized = RemotePath.normalized(path)
        if nodes[normalized] != nil { return normalized }
        guard caseInsensitive else { return nil }
        return nodes.keys.first { $0.lowercased() == normalized.lowercased() }
    }

    /// POSIX-ish word splitting with single quotes and backslash escapes (enough for `AdbShell.quote`).
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var hasToken = false
        var iterator = command.makeIterator()
        while let char = iterator.next() {
            if inQuote {
                if char == "'" { inQuote = false } else { current.append(char) }
            } else if char == "'" {
                inQuote = true
                hasToken = true
            } else if char == "\\" {
                if let next = iterator.next() { current.append(next); hasToken = true }
            } else if char == " " {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
            } else {
                current.append(char)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
