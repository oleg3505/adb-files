import Testing
@testable import AdbKit

@Suite("AdbKit smoke")
struct AdbKitTests {
    @Test("library links and exposes a version")
    func versionIsNotEmpty() {
        #expect(!AdbKit.version.isEmpty)
    }
}
