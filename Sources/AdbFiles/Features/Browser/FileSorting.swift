import AdbKit
import Foundation
import UniformTypeIdentifiers

/// Table column a listing can be sorted by.
enum SortKey: String, Sendable, CaseIterable {
    case name, date, size, kind
}

/// Current sort order. Folders always come first, whatever the direction.
struct FileSort: Equatable, Sendable {
    var key: SortKey = .name
    var ascending = true
}

/// One table row: the file plus display strings, computed off the main thread.
struct FileRow: Sendable, Hashable, Identifiable {
    let file: RemoteFile
    let kind: String
    let sizeText: String
    let dateText: String

    var id: String { file.path }
    var name: String { file.name }
    /// Whether opening the row navigates into it (folders and symlinks, which may point to folders).
    var isNavigable: Bool { file.isDirectory || file.isSymlink }
}

enum FileSorting {
    /// Builds sorted, filtered rows. Pure and `Sendable`, so it runs on a background task.
    static func rows(from files: [RemoteFile], sort: FileSort, showHidden: Bool) -> [FileRow] {
        var kindCache: [String: String] = [:]
        let rows = files
            .filter { showHidden || !$0.isHidden }
            .map { file -> FileRow in
                FileRow(file: file, kind: kind(of: file, cache: &kindCache), sizeText: sizeText(file), dateText: dateText(file))
            }
        return rows.sorted { lhs, rhs in
            if lhs.file.isDirectory != rhs.file.isDirectory { return lhs.file.isDirectory }
            let order = compare(lhs, rhs, by: sort.key)
            if order == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare(_ lhs: FileRow, _ rhs: FileRow, by key: SortKey) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .date:
            let left = lhs.file.modificationDate ?? .distantPast
            let right = rhs.file.modificationDate ?? .distantPast
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case .size:
            // Folder sizes are meaningless (block size), so folders compare equal and fall back to name.
            if lhs.file.isDirectory && rhs.file.isDirectory { return .orderedSame }
            return lhs.file.size == rhs.file.size ? .orderedSame : (lhs.file.size < rhs.file.size ? .orderedAscending : .orderedDescending)
        case .kind:
            return lhs.kind.localizedStandardCompare(rhs.kind)
        }
    }

    static func kind(of file: RemoteFile, cache: inout [String: String]) -> String {
        if file.isDirectory { return "Folder" }
        if file.isSymlink { return "Alias" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return "Document" }
        if let cached = cache[ext] { return cached }
        let description = UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) file"
        cache[ext] = description
        return description
    }

    static func sizeText(_ file: RemoteFile) -> String {
        if file.hasError { return "—" }
        if file.isDirectory || file.isSymlink { return "--" }
        return Int64(clamping: file.size).formatted(.byteCount(style: .file))
    }

    static func dateText(_ file: RemoteFile) -> String {
        guard let date = file.modificationDate else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
