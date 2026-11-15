import Testing
@testable import AdbFiles

@Suite struct DragHintTextTests {
    @Test func textPerKindAndTarget() {
        #expect(DragHintText.make(.move, folder: "/sdcard/Download/AdbFilesTest/sub") == "Move to “sub”")
        #expect(DragHintText.make(.copy, folder: "/sdcard/DCIM") == "Copy to “DCIM”")
        #expect(DragHintText.make(.upload, folder: "/sdcard/Download/Звіти 🙂") == "Upload to “Звіти 🙂”")
        #expect(DragHintText.make(.move, folder: "/") == "Move to “/”")
    }
}
