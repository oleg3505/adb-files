import CoreGraphics

/// View › Small Rows / Large Rows: the file table's row height and icon (or thumbnail) size.
enum RowSize: String, CaseIterable, Sendable {
    case small
    case large

    /// The `@AppStorage` key for the user's choice.
    static let storageKey = "rowSize"

    var rowHeight: CGFloat {
        switch self {
        case .small: 22
        case .large: 48
        }
    }

    /// Icon and thumbnail size in points.
    var iconSize: CGFloat {
        switch self {
        case .small: 16
        case .large: 40
        }
    }

    /// Pixel size of generated thumbnails. One size for both, so switching never regenerates the cache
    /// (160 px is sharp at 40 pt on a 2× display).
    var thumbnailPixels: Int { ThumbnailService.pixelSize }

    var menuTitle: String {
        switch self {
        case .small: "Small Rows"
        case .large: "Large Rows"
        }
    }
}
