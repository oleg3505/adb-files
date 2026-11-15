import AppKit

/// Asks about one name clash with a sheet on the key window (an app-modal alert when there is none).
///
/// Buttons follow Finder: Keep Both (default, Return), Replace (files only), Skip, Stop (Esc). With more clashes of
/// the same kind to come, a checkbox applies the answer to all of them.
@MainActor
enum ConflictPrompt {
    /// The prompt being shown; the next one waits for it (several dropped items each ask in turn).
    private static var current: Task<ConflictAnswer, Never>?

    static func ask(_ question: ConflictQuestion) async -> ConflictAnswer {
        let previous = current
        let task = Task { @MainActor in
            _ = await previous?.value
            return await present(question)
        }
        current = task
        return await task.value
    }

    private static func present(_ question: ConflictQuestion) async -> ConflictAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let kind = question.isFolder ? "A folder" : "An item"
        alert.messageText = "\(kind) named “\(question.name)” already exists in “\(question.destination)”."
        alert.informativeText = question.isFolder
            ? "Keep both to copy it under a new name, or skip it."
            : "Do you want to replace it with the one you’re copying?"
        var choices: [ConflictChoice?] = []
        alert.addButton(withTitle: "Keep Both")
        choices.append(.keepBoth)
        if !question.isFolder {
            alert.addButton(withTitle: "Replace")
            choices.append(.replace)
        }
        alert.addButton(withTitle: "Skip")
        choices.append(.skip)
        let stop = alert.addButton(withTitle: "Stop")
        stop.keyEquivalent = "\u{1b}"
        choices.append(nil)
        if question.remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to all \(question.remaining) \(question.isFolder ? "folders" : "files")"
        }

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choice = choices.indices.contains(index) ? choices[index] : nil
        return ConflictAnswer(choice: choice, applyToAll: alert.suppressionButton?.state == .on)
    }
}
