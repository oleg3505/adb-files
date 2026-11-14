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

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible && isControlling
    }

    func show(_ urls: [URL]) {
        items = urls.map(PreviewItem.init(url:))
        guard let panel = QLPreviewPanel.shared() else { return }
        if isControlling {
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard isControlling, let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
    }

    // MARK: Called by the table (QLPreviewPanelController)

    func begin(_ panel: QLPreviewPanel) {
        isControlling = true
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func end(_ panel: QLPreviewPanel) {
        isControlling = false
        panel.dataSource = nil
        panel.delegate = nil
        onClose()
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
