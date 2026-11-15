/// Fixed "Locations" in the sidebar and the Go menu (CLAUDE.md § UI); they act on the selected device.
struct Bookmark: Identifiable, Hashable, Sendable {
    let name: String
    let symbol: String
    let path: String

    var id: String { path }

    static let all: [Bookmark] = [
        Bookmark(name: "Internal Storage", symbol: "internaldrive", path: "/sdcard"),
        Bookmark(name: "DCIM", symbol: "camera", path: "/sdcard/DCIM"),
        Bookmark(name: "Download", symbol: "arrow.down.circle", path: "/sdcard/Download"),
        Bookmark(name: "Documents", symbol: "doc", path: "/sdcard/Documents"),
        Bookmark(name: "Pictures", symbol: "photo", path: "/sdcard/Pictures"),
        Bookmark(name: "Music", symbol: "music.note", path: "/sdcard/Music"),
    ]
}
