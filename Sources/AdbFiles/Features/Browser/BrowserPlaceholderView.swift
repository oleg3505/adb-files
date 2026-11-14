import SwiftUI

/// Detail area shown until a device is selected. Replaced by the file table in milestone 3.
struct BrowserPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "No Device Selected",
            systemImage: "externaldrive.badge.questionmark",
            description: Text("Connect an Android device with USB debugging enabled.")
        )
    }
}
