import AdbKit
import SwiftUI

/// Path segments as buttons; clicking one navigates to that folder.
struct BreadcrumbBar: View {
    let path: String
    let navigate: (String) -> Void

    private var segments: [(title: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var current = ""
        for component in RemotePath.components(path) {
            current += "/" + component
            result.append((component, current))
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            navigate(segment.path)
                        } label: {
                            Label(segment.title, systemImage: index == 0 ? "iphone" : "folder")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(index == segments.count - 1 ? .primary : .secondary)
                        .accessibilityLabel(index == 0 ? "Device root" : segment.title)
                        .id(index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .onChange(of: path) { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
        }
        .font(.callout)
    }
}
