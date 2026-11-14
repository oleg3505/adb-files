import Foundation
import Testing
@testable import AdbKit

@Suite("Shell quoting")
struct AdbShellTests {
    @Test(arguments: [
        ("plain", "'plain'"),
        ("", "''"),
        ("with space", "'with space'"),
        ("it's", "'it'\\''s'"),
        ("''", "''\\'''\\'''"),
        ("$(rm -rf /)", "'$(rm -rf /)'"),
        ("`id`; echo hi", "'`id`; echo hi'"),
        ("Фото ВІДПУСТКА", "'Фото ВІДПУСТКА'"),
        ("🎉 party", "'🎉 party'"),
        ("line1\nline2", "'line1\nline2'"),
    ])
    func quotes(input: String, expected: String) {
        #expect(AdbShell.quote(input) == expected)
    }

    @Test func buildsCommand() {
        #expect(AdbShell.command("mkdir -p", ["/sdcard/New Folder"]) == "mkdir -p '/sdcard/New Folder'")
    }

    @Test func accessCheckQuotesPathTwice() {
        #expect(AdbShell.accessCheck("/x") == "test -r '/x' -a -x '/x' && echo ok || echo denied")
        #expect(AdbShell.accessCheck("/a b/it's") == "test -r '/a b/it'\\''s' -a -x '/a b/it'\\''s' && echo ok || echo denied")
    }

    @Test func quotedArgumentRoundTripsThroughRealShell() throws {
        // Run the quoted strings through /bin/sh locally: the shell must hand back each input unchanged.
        let inputs = ["it's", "$(echo pwned)", "a\nb", "Фото 🎉", "  spaced  ", "back\\slash"]
        for input in inputs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s " + AdbShell.quote(input)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(output == input)
        }
    }
}
