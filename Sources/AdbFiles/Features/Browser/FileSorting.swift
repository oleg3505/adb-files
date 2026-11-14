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
    /// Position in Finder name order within the listing; precomputed so sorting compares integers.
    var nameRank = 0
    /// Position of `kind` in Finder name order; precomputed like `nameRank`.
    var kindRank = 0

    var id: String { file.path }
    var name: String { file.name }
    /// Whether opening the row navigates into it (folders and symlinks, which may point to folders).
    var isNavigable: Bool { file.isDirectory || file.isSymlink }
}

enum FileSorting {
    /// Builds sorted, filtered rows in one go.
    static func rows(from files: [RemoteFile], sort: FileSort, showHidden: Bool) -> [FileRow] {
        arrange(buildRows(from: files), sort: sort, showHidden: showHidden)
    }

    /// Builds display rows (kind, size and date strings, name and kind ranks) once per listing.
    /// The expensive part: it runs the only locale-aware string sorts.
    static func buildRows(from files: [RemoteFile]) -> [FileRow] {
        var kindCache: [String: String] = [:]
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
        var rows = files.map { file in
            FileRow(
                file: file, kind: kind(of: file, cache: &kindCache), sizeText: sizeText(file),
                dateText: file.modificationDate.map { $0.formatted(dateStyle) } ?? "—"
            )
        }
        let byName = rows.indices.sorted { rows[$0].name.localizedStandardCompare(rows[$1].name) == .orderedAscending }
        for (rank, index) in byName.enumerated() { rows[index].nameRank = rank }
        let kinds = Set(rows.map(\.kind)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let kindRanks = Dictionary(uniqueKeysWithValues: kinds.enumerated().map { ($1, $0) })
        for index in rows.indices { rows[index].kindRank = kindRanks[rows[index].kind] ?? 0 }
        return rows
    }

    /// Filters and sorts already-built rows; cheap enough for every header click.
    ///
    /// Sorts an index array over plain integer keys instead of moving the (large) rows on every swap.
    static func arrange(_ rows: [FileRow], sort: FileSort, showHidden: Bool) -> [FileRow] {
        let visible = showHidden ? rows : rows.filter { !$0.file.isHidden }
        let folder = visible.map(\.file.isDirectory)
        let nameRank = visible.map(\.nameRank)
        let primary: [Int64] = visible.map { row in
            switch sort.key {
            case .name: Int64(row.nameRank)
            case .kind: Int64(row.kindRank)
            case .date: Int64((row.file.modificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
            // Folder sizes are meaningless (block size), so folders tie and fall back to name.
            case .size: row.file.isDirectory ? 0 : Int64(clamping: row.file.size)
            }
        }
        let ascending = sort.ascending
        var order = Array(visible.indices)
        order.sort { a, b in
            if folder[a] != folder[b] { return folder[a] }
            if primary[a] != primary[b] { return ascending ? primary[a] < primary[b] : primary[a] > primary[b] }
            return nameRank[a] < nameRank[b]
        }
        return order.map { visible[$0] }
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
