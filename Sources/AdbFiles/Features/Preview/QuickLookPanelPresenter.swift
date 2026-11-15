import AppKit
import Quartz

/// One item in the Quick Look panel.
final class PreviewItem: NSObject, QLPreviewItem {
    let url: URL

    init(url: URL) { self.url = url }

    var previewItemURL: URL? { url }
    var previewItemTitle: String? { url.lastPathComponent }
}

/// Drives the shared `QLPreviewPanel` for one file table.
///
/// The panel finds its controller through the responder chain: the table (first responder) answers
/// `acceptsPreviewPanelControl` and hands the panel to this object as data source and delegate.
@MainActor
final class QuickLookPanelPresenter: NSObject, PreviewPresenting {
    private var items: [PreviewItem] = []
    /// The table that controls the panel; ↑/↓ pressed in the panel are forwarded to it.
    weak var table: NSTableView?
    /// The user closed the panel (Esc, Space in the panel, close button).
    var onClose: () -> Void = {}
    /// Space pressed while the panel is key.
    var onToggle: () -> Void = {}
    private var isControlling = false
    /// Set while this presenter wants the panel up; the table accepts panel control only then, so another window's
    /// table never takes the panel with leftover items.
    private(set) var wantsPanel = false

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible && isControlling
    }

    func show(_ urls: [URL]) {
        items = urls.map(PreviewItem.init(url:))
        wantsPanel = true
        guard let panel = QLPreviewPanel.shared() else { return }
        // The panel finds its controller through the responder chain: make sure it starts at our table (the
        // context menu can be used while focus is elsewhere).
        if let table, table.window?.firstResponder !== table {
            table.window?.makeFirstResponder(table)
        }
        if !isControlling { panel.updateController() }
        if isControlling {
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        wantsPanel = false
        guard isControlling, let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
        detach(from: panel)
    }

    // MARK: Called by the table (QLPreviewPanelController)

    func begin(_ panel: QLPreviewPanel) {
        isControlling = true
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func end(_ panel: QLPreviewPanel) {
        guard isControlling else { return }
        detach(from: panel)
        items = []
        wantsPanel = false
        onClose()
    }

    /// The panel holds its data source and delegate unretained: never leave it pointing at us.
    private func detach(from panel: QLPreviewPanel) {
        isControlling = false
        if (panel.dataSource as AnyObject?) === self { panel.dataSource = nil }
        if (panel.delegate as AnyObject?) === self { panel.delegate = nil }
    }
}

extension QuickLookPanelPresenter: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items.indices.contains(index) ? items[index] : nil
    }

    /// ↑/↓ move the table selection (the panel then follows it); Space closes, like Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125, 126: // ↓, ↑
            table?.keyDown(with: event)
            return true
        case 49: // Space
            onToggle()
            return true
        default:
            return false
        }
    }
}
