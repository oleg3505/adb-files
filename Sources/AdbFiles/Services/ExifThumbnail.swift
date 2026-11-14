import Foundation

/// Finds the JPEG thumbnail embedded in a JPEG's EXIF data (APP1 → TIFF → IFD1 tags 0x0201/0x0202).
///
/// ImageIO can't be trusted with a truncated file: asked for an embedded thumbnail only, it may still return a
/// partly decoded main image. Extracting the complete thumbnail bytes ourselves avoids that.
enum ExifThumbnail {
    struct Result: Equatable {
        /// A complete JPEG (starts with FF D8).
        let jpeg: Data
        /// EXIF orientation of the main image (1…8), applied to the thumbnail.
        let orientation: Int
    }

    /// The embedded thumbnail, or nil when there is none or it is not fully inside `data`.
    static func extract(from data: Data) -> Result? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue }
            if marker == 0xDA || marker == 0xD9 { return nil } // image data starts: no EXIF before it
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let segmentStart = index + 4
            let segmentEnd = index + 2 + length
            if marker == 0xE1, segmentEnd <= bytes.count, segmentEnd - segmentStart > 6,
               Array(bytes[segmentStart..<segmentStart + 6]) == [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] {
                return parseTIFF(bytes, start: segmentStart + 6, end: segmentEnd)
            }
            index = segmentEnd
        }
        return nil
    }

    private static func parseTIFF(_ bytes: [UInt8], start: Int, end: Int) -> Result? {
        guard end - start >= 8 else { return nil }
        let little: Bool
        switch (bytes[start], bytes[start + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ offset: Int) -> Int? {
            let at = start + offset
            guard offset >= 0, at + 2 <= end else { return nil }
            return little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
        }
        func u32(_ offset: Int) -> Int? {
            guard let low = u16(little ? offset : offset + 2), let high = u16(little ? offset + 2 : offset) else { return nil }
            return high << 16 | low
        }
        guard let ifd0 = u32(4), let count0 = u16(ifd0) else { return nil }
        var orientation = 1
        for entry in 0..<count0 {
            let at = ifd0 + 2 + entry * 12
            if u16(at) == 0x0112, let value = u16(at + 8) { orientation = (1...8).contains(value) ? value : 1 }
        }
        guard let ifd1 = u32(ifd0 + 2 + count0 * 12), ifd1 > 0, let count1 = u16(ifd1) else { return nil }
        var offset: Int?
        var length: Int?
        for entry in 0..<count1 {
            let at = ifd1 + 2 + entry * 12
            switch u16(at) {
            case 0x0201: offset = u32(at + 8)
            case 0x0202: length = u32(at + 8)
            default: break
            }
        }
        guard let offset, let length, length > 4, start + offset + length <= end else { return nil }
        let jpeg = Data(bytes[(start + offset)..<(start + offset + length)])
        guard jpeg.starts(with: [0xFF, 0xD8]) else { return nil }
        return Result(jpeg: jpeg, orientation: orientation)
    }
}
