import AdbKit
import Foundation
import Testing
@testable import AdbFiles

@Suite("File sorting")
struct FileSortingTests {
    private let sample = [
        file("IMG_10.jpg", size: 300, mtime: 30),
        file("IMG_2.jpg", size: 100, mtime: 10),
        file("notes.txt", size: 200, mtime: 20),
        file("Music", folder: true, mtime: 5),
        file("DCIM", folder: true, mtime: 50),
    ]

    private func names(_ sort: FileSort, hidden: Bool = false, files: [RemoteFile]? = nil) -> [String] {
        FileSorting.rows(from: files ?? sample, sort: sort, showHidden: hidden).map(\.name)
    }

    @Test func nameUsesFinderOrderWithFoldersFirst() {
        #expect(names(FileSort(key: .name)) == ["DCIM", "Music", "IMG_2.jpg", "IMG_10.jpg", "notes.txt"])
    }

    @Test func descendingKeepsFoldersFirst() {
        #expect(names(FileSort(key: .name, ascending: false)) == ["Music", "DCIM", "notes.txt", "IMG_10.jpg", "IMG_2.jpg"])
    }

    @Test func sortsBySize() {
        #expect(names(FileSort(key: .size)) == ["DCIM", "Music", "IMG_2.jpg", "notes.txt", "IMG_10.jpg"])
    }

    @Test func sortsByDate() {
        #expect(names(FileSort(key: .date)) == ["Music", "DCIM", "IMG_2.jpg", "notes.txt", "IMG_10.jpg"])
        #expect(names(FileSort(key: .date, ascending: false)) == ["DCIM", "Music", "IMG_10.jpg", "notes.txt", "IMG_2.jpg"])
    }

    @Test func sortsByKindThenName() {
        let rows = FileSorting.rows(from: sample, sort: FileSort(key: .kind), showHidden: false)
        #expect(rows.prefix(2).map(\.kind) == ["Folder", "Folder"])
        let fileKinds = rows.dropFirst(2).map(\.kind)
        #expect(fileKinds == fileKinds.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func hidesDotFilesUnlessAsked() {
        let files = [file(".nomedia"), file("a.jpg")]
        #expect(names(FileSort(), files: files) == ["a.jpg"])
        #expect(names(FileSort(), hidden: true, files: files) == [".nomedia", "a.jpg"])
    }

    @Test func entryWithErrorShowsDashes() throws {
        let broken = RemoteFile(name: "ghost", path: "/proc/ghost", mode: 0, size: 0, modificationDate: nil, errorCode: 13)
        let row = try #require(FileSorting.rows(from: [broken], sort: FileSort(), showHidden: true).first)
        #expect(row.sizeText == "—")
        #expect(row.dateText == "—")
    }

    @Test func folderSizeIsDoubleDashAndBigFilesUseGigabytes() throws {
        let rows = FileSorting.rows(
            from: [file("Movies", folder: true), file("big.mkv", size: 5_368_709_120)], sort: FileSort(), showHidden: false
        )
        #expect(rows[0].sizeText == "--")
        #expect(rows[1].sizeText.contains("GB"))
    }

    @Test func cyrillicNamesSortNaturally() {
        let files = [file("Яблуко.txt"), file("Абетка.txt"), file("Їжак.txt")]
        #expect(names(FileSort(), files: files) == ["Абетка.txt", "Їжак.txt", "Яблуко.txt"])
    }
}

@Suite("Listing cache")
struct ListingCacheTests {
    @Test func reportsChangesIgnoringOrder() async {
        let cache = ListingCache()
        #expect(await cache.store([file("a"), file("b")], serial: "S", path: "/x") == true)
        #expect(await cache.store([file("b"), file("a")], serial: "S", path: "/x") == false)
        #expect(await cache.store([file("b"), file("a", size: 2)], serial: "S", path: "/x") == true)
    }

    @Test func keysByDeviceAndPath() async {
        let cache = ListingCache()
        await cache.store([file("a")], serial: "S1", path: "/x")
        #expect(await cache.cached(serial: "S2", path: "/x") == nil)
        #expect(await cache.cached(serial: "S1", path: "/y") == nil)
        #expect(await cache.cached(serial: "S1", path: "/x")?.count == 1)
    }
}
