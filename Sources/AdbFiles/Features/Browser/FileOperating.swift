import AdbKit
import Foundation

/// File operations on one device. `AdbFileOperations` in production, a scripted fake in tests.
protocol FileOperating: Sendable {
    func rename(_ path: String, to newName: String) async throws -> String
    func move(_ paths: [String], into folder: String) async -> [String: Result<String, AdbError>]
    func copy(_ paths: [String], into folder: String) async -> [String: Result<String, AdbError>]
    func delete(_ paths: [String]) async -> [String: Result<Void, AdbError>]
    func makeDirectory(_ path: String) async throws
}

extension AdbFileOperations: FileOperating {}

/// An error to show after an operation.
struct OperationAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// Validates a new file or folder name typed by the user. Returns a message, or nil when the name is fine.
enum NameValidation {
    static func problem(with name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The name can’t be empty." }
        if name.contains("/") { return "The name can’t contain “/”." }
        if name == "." || name == ".." { return "“\(name)” is reserved." }
        if name.utf8.count > 255 { return "The name is too long." }
        return nil
    }
}
