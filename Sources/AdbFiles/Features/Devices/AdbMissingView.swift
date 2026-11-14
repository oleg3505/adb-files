import AppKit
import SwiftUI

/// Shown when the ADB server is not running and no `adb` executable can be found.
struct AdbMissingView: View {
    let retry: () -> Void

    private let command = "brew install android-platform-tools"

    var body: some View {
        ContentUnavailableView {
            Label("adb Not Found", systemImage: "wrench.and.screwdriver")
        } description: {
            VStack(spacing: 8) {
                Text("AdbFiles needs Android platform tools. Install them with Homebrew:")
                HStack {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy command")
                    .accessibilityLabel("Copy command")
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        } actions: {
            Button("Retry", action: retry)
                .keyboardShortcut(.defaultAction)
        }
    }
}
