import SwiftUI

/// View › Small Rows / Large Rows (remembered across launches).
struct ViewCommands: Commands {
    // @AppStorage is a UserDefaults-backed @State: every view reading the same key updates together.
    @AppStorage(RowSize.storageKey) private var rowSize: RowSize = .small

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Picker("Row Size", selection: $rowSize) {
                ForEach(RowSize.allCases, id: \.self) { size in
                    Text(size.menuTitle).tag(size)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
        }
    }
}
