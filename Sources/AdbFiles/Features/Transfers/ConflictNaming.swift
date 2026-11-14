import Foundation

/// Finder-style "keep both" names: `a.txt` → `a 2.txt` → `a 3.txt`; `a 2.txt` → `a 3.txt`.
enum ConflictNaming {
    /// The first name, starting with `name`, for which `isTaken` returns false.
    static func uniqueName(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let (stem, ext, start) = split(name)
        var number = start
        while true {
            number += 1
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !isTaken(candidate) { return candidate }
        }
    }

    /// Splits `photo 2.jpg` into (`photo`, `jpg`, 2) and `photo.jpg` into (`photo`, `jpg`, 1).
    /// Dot-files (`.nomedia`) have no extension.
    static func split(_ name: String) -> (stem: String, ext: String, number: Int) {
        var stem = name
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            ext = String(name[name.index(after: dot)...])
        }
        if let space = stem.lastIndex(of: " "), let number = Int(stem[stem.index(after: space)...]), number >= 2 {
            return (String(stem[..<space]), ext, number)
        }
        return (stem, ext, 1)
    }
}
