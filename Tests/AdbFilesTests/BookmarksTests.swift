import AdbKit
import Testing
@testable import AdbFiles

@Suite struct BookmarksTests {
    @Test func theSixLocationsFromCLAUDEmd() {
        #expect(Bookmark.all.map(\.name) == ["Internal Storage", "DCIM", "Download", "Documents", "Pictures", "Music"])
        #expect(Bookmark.all.map(\.path) == [
            "/sdcard", "/sdcard/DCIM", "/sdcard/Download", "/sdcard/Documents", "/sdcard/Pictures", "/sdcard/Music",
        ])
        #expect(Set(Bookmark.all.map(\.id)).count == Bookmark.all.count)
        #expect(Bookmark.all.allSatisfy { RemotePath.normalized($0.path) == $0.path })
    }

    @MainActor
    @Test func bookmarkNavigationKeepsBackHistoryAndAMissingFolderIsNotFound() async throws {
        let listing = FakeListing()
        listing.script("/sdcard/Music", .failure(.notFound("/sdcard/Music")))
        let store = BrowserStore(serial: "A", listing: listing, cache: ListingCache())
        store.start()
        store.navigate(to: "/sdcard/DCIM", action: "bookmark")
        store.navigate(to: "/sdcard/Music", action: "bookmark")
        try await waitUntil { store.phase == .notFound }
        store.goBack()
        #expect(store.path == "/sdcard/DCIM")
    }
}
