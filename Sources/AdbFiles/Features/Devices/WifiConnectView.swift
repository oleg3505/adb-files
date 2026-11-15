import SwiftUI

/// "Connect via Wi-Fi" window: pair once with a code, then connect (Android 11+ Wireless debugging).
struct WifiConnectView: View {
    static let windowID = "wifi-connect"

    @State private var model = WifiConnectModel()

    var body: some View {
        Form {
            Section {
                TextField("IP address and port", text: $model.pairAddress, prompt: Text("192.168.1.20:37099"))
                TextField("Pairing code", text: $model.pairCode, prompt: Text("123456"))
                HStack {
                    Spacer()
                    if model.busy == .pair { ProgressView().controlSize(.small) }
                    Button("Pair") { Task { await model.pair() } }
                        .disabled(!model.canPair)
                }
            } header: {
                Text("1. Pair (once per phone)")
            } footer: {
                Text("On the phone: Developer options › Wireless debugging › Pair device with pairing code.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("IP address and port", text: $model.connectAddress, prompt: Text("192.168.1.20:41234"))
                HStack {
                    Spacer()
                    if model.busy == .connect { ProgressView().controlSize(.small) }
                    Button("Connect") { Task { await model.connect() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canConnect)
                }
            } header: {
                Text("2. Connect")
            } footer: {
                Text("Use the address and port shown at the top of the Wireless debugging screen. The phone then appears in the sidebar.")
                    .foregroundStyle(.secondary)
            }
            if let status = model.status {
                Label(status.text, systemImage: status.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
                    .accessibilityLabel(status.isError ? "Error: \(status.text)" : status.text)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
