import AdbKit
import Foundation
import os
import Testing
@testable import AdbFiles

/// Names per destination folder; counts lookups.
final class FakeNames: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (names: [String: Set<String>](), folders: Set<String>(), calls: [String](), failing: Set<String>()))

    /// - Parameter folders: Names (in any folder) that are folders.
    init(_ names: [String: Set<String>], folders: Set<String> = [], failing: Set<String> = []) {
        state.withLock { $0.names = names; $0.folders = folders; $0.failing = failing }
    }

    var calls: [String] { state.withLock { $0.calls } }

    var lookup: ConflictPlanner.Lookup {
        { [state] request in
            try state.withLock { state in
                state.calls.append(request.targetFolder)
                if state.failing.contains(request.targetFolder) { throw AdbError.timeout }
                let folders = state.folders
                return Dictionary(uniqueKeysWithValues: (state.names[request.targetFolder] ?? []).map { ($0, folders.contains($0)) })
            }
        }
    }
}

/// Scripted answers; records the questions.
@MainActor
final class ScriptedAnswers {
    var answers: [ConflictAnswer]
    var questions: [ConflictQuestion] = []

    init(_ answers: [ConflictAnswer]) { self.answers = answers }

    func ask(_ question: ConflictQuestion) async -> ConflictAnswer {
        questions.append(question)
        return answers.isEmpty ? .stop : answers.removeFirst()
    }
}

private func up(_ name: String, folder: Bool = false, to target: String = "/sdcard/Download") -> TransferRequest {
    TransferRequest(direction: .upload, serial: "S", sourcePath: "/Users/me/\(name)", isFolder: folder, targetFolder: target)
}

private func down(_ name: String, to target: String = "/Users/me/Desktop") -> TransferRequest {
    TransferRequest(direction: .download, serial: "S", sourcePath: "/sdcard/\(name)", isFolder: false, targetFolder: target)
}

@MainActor
@Suite struct ConflictPlannerTests {
    private func planner(_ names: FakeNames, _ answers: ScriptedAnswers) -> ConflictPlanner {
        ConflictPlanner(lookup: names.lookup, ask: { await answers.ask($0) })
    }

    @Test func noClashAsksNothing() async {
        let answers = ScriptedAnswers([])
        let planned = await planner(FakeNames(["/sdcard/Download": ["other.txt"]]), answers).plan([up("a.txt"), up("b.txt")])
        #expect(planned.map(\.name) == ["a.txt", "b.txt"])
        #expect(planned.allSatisfy { $0.conflict == .keepBoth })
        #expect(answers.questions.isEmpty)
    }

    @Test func eachFileChoiceDoesWhatItSays() async {
        let names = FakeNames(["/sdcard/Download": ["a.txt", "b.txt", "c.txt"]])
        let answers = ScriptedAnswers([.init(choice: .replace), .init(choice: .keepBoth), .init(choice: .skip)])
        let planned = await planner(names, answers).plan([up("a.txt"), up("b.txt"), up("c.txt"), up("new.txt")])
        #expect(planned.map(\.name) == ["a.txt", "b.txt", "new.txt"], "skipped item left out")
        #expect(planned.map(\.conflict) == [.replace, .keepBoth, .keepBoth])
        #expect(answers.questions.map(\.remaining) == [3, 2, 1])
    }

    @Test func applyToAllAsksOnceForTheSameKind() async {
        let names = FakeNames(["/sdcard/Download": ["a.txt", "b.txt", "c.txt"]])
        let answers = ScriptedAnswers([.init(choice: .replace, applyToAll: true)])
        let planned = await planner(names, answers).plan([up("a.txt"), up("b.txt"), up("c.txt")])
        #expect(answers.questions.count == 1)
        #expect(planned.map(\.conflict) == [.replace, .replace, .replace])
    }

    @Test func foldersAreNeverReplacedAndAskedSeparately() async {
        let names = FakeNames(["/sdcard/Download": ["Photos", "a.txt"]])
        // Even if something answered Replace for a folder, it becomes Keep Both.
        let answers = ScriptedAnswers([.init(choice: .replace, applyToAll: true), .init(choice: .replace)])
        let planned = await planner(names, answers).plan([up("a.txt"), up("Photos", folder: true)])
        #expect(answers.questions.map(\.isFolder) == [false, true], "a file's apply-to-all doesn't answer for folders")
        #expect(planned.map(\.conflict) == [.replace, .keepBoth])
    }

    @Test func stopEnqueuesNothing() async {
        let names = FakeNames(["/sdcard/Download": ["a.txt"]])
        let planned = await planner(names, ScriptedAnswers([.stop])).plan([up("new.txt"), up("a.txt")])
        #expect(planned.isEmpty)
    }

    @Test func oneLookupPerDestinationFolder() async {
        let names = FakeNames(["/sdcard/Download": [], "/sdcard/DCIM": []])
        _ = await planner(names, ScriptedAnswers([])).plan([up("a"), up("b"), up("c", to: "/sdcard/DCIM"), up("d")])
        #expect(names.calls.sorted() == ["/sdcard/DCIM", "/sdcard/Download"])
    }

    @Test func namesCompareWithoutCaseInBothDirections() async {
        let answers = ScriptedAnswers([.init(choice: .skip), .init(choice: .skip)])
        let names = FakeNames(["/sdcard/Download": ["A.TXT"], "/Users/me/Desktop": ["B.TXT"]])
        let planned = await planner(names, answers).plan([up("a.txt"), down("b.txt")])
        #expect(answers.questions.map(\.name) == ["a.txt", "b.txt"], "/sdcard and APFS are case-insensitive")
        #expect(planned.isEmpty)
    }

    @Test func aFileClashingWithAnExistingFolderIsNeverReplaced() async {
        // A remote file "Photos" downloaded where the Mac has a folder "Photos": Replace would delete the folder.
        let names = FakeNames(["/Users/me/Desktop": ["Photos"], "/sdcard/Download": ["foo"]], folders: ["Photos", "foo"])
        let answers = ScriptedAnswers([.init(choice: .replace), .init(choice: .replace)])
        let planned = await planner(names, answers).plan([down("Photos"), up("foo")])
        #expect(answers.questions.map(\.isFolder) == [true, true], "asked as a folder clash: no Replace button")
        #expect(planned.map(\.conflict) == [.keepBoth, .keepBoth])
    }

    @Test func failedLookupGoesAheadWithKeepBoth() async {
        let answers = ScriptedAnswers([])
        let planned = await planner(FakeNames([:], failing: ["/sdcard/Download"]), answers).plan([up("a.txt")])
        #expect(planned.map(\.conflict) == [.keepBoth])
        #expect(answers.questions.isEmpty)
    }

    @Test func finderPromisesAreNotChecked() async {
        var promise = down("a.txt")
        promise.fixedName = "a.txt"
        let names = FakeNames(["/Users/me/Desktop": ["a.txt"]])
        let planned = await planner(names, ScriptedAnswers([])).plan([promise])
        #expect(planned.count == 1)
        #expect(names.calls.isEmpty)
    }
}
