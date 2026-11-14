import AdbKit
import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// Path segments as buttons; clicking one navigates to that folder. Like Finder's path bar, each segment is
/// also a drop target: rows dragged from the table move there (⌥ copies), Finder items are uploaded there.
struct BreadcrumbBar: View {
    let path: String
    let navigate: (String) -> Void
    /// Rows being dragged from this browser's table, if any.
    var draggingPaths: [String] = []
    /// Moves (or, with ⌥, copies) the dragged rows into a folder.
    var moveRows: (_ paths: [String], _ folder: String, _ copy: Bool) -> Void = { _, _, _ in }
    /// Uploads Finder items into a folder.
    var uploadFiles: (_ urls: [URL], _ folder: String) -> Void = { _, _ in }

    @State private var targeted: String?

    /// Our rows are dragged as file promises; Finder items as file URLs.
    private static let dropTypes: [UTType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { UTType(importedAs: $0) }

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
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(targeted == segment.path ? Color.accentColor.opacity(0.25) : .clear)
                                )
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(index == segments.count - 1 ? .primary : .secondary)
                        .accessibilityLabel(index == 0 ? "Device root" : segment.title)
                        .onDrop(of: Self.dropTypes, isTargeted: Binding(
                            get: { targeted == segment.path },
                            set: { targeted = $0 && acceptsDrop(on: segment.path) ? segment.path : (targeted == segment.path ? nil : targeted) }
                        )) { providers in
                            drop(providers, on: segment.path)
                        }
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

    /// Dragged rows may not go into the folder they are already in, nor into themselves or a descendant.
    private func acceptsDrop(on folder: String) -> Bool {
        guard !draggingPaths.isEmpty else { return true } // Finder items: always accepted
        return draggingPaths.allSatisfy { dragged in
            RemotePath.parent(of: dragged) != folder && folder != dragged && !folder.hasPrefix(dragged + "/")
        }
    }

    private func drop(_ providers: [NSItemProvider], on folder: String) -> Bool {
        targeted = nil
        if !draggingPaths.isEmpty {
            guard acceptsDrop(on: folder) else { return false }
            // SwiftUI's onDrop doesn't expose the negotiated operation; the ⌥ state at drop time is the best signal here.
            let copy = NSEvent.modifierFlags.contains(.option)
            Logger.ui.info("drop op=\(copy ? "copy" : "move", privacy: .public) count=\(self.draggingPaths.count) dest=\(folder, privacy: .public) via=breadcrumb")
            moveRows(draggingPaths, folder, copy)
            return true
        }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let upload = uploadFiles
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                    urls.append(fileURL)
                }
            }
            if !urls.isEmpty { upload(urls, folder) }
        }
        return true
    }
}
