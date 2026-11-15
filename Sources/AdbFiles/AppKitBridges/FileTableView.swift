import AppKit
import os
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Callbacks for editing, context menus and moving rows within the device.
struct FileTableActions {
    /// Whether a file operation may start now (one at a time).
    var canOperate = false
    var beginRename: (String) -> Void = { _ in }
    var commitRename: (_ path: String, _ newName: String) -> Void = { _, _ in }
    var cancelRename: () -> Void = {}
    /// Rows dragged onto a folder row of the same table: move, or copy with ⌥.
    var moveRows: (_ paths: [String], _ folder: String, _ copy: Bool) -> Void = { _, _, _ in }
    /// Items for the context menu: the clicked row (nil = background) and the selection after the click.
    var menuItems: (_ clicked: FileRow?, _ selection: [FileRow]) -> [NSMenuItem] = { _, _ in [] }
    /// A drag of rows started (paths) or ended (empty), so other drop targets can move them.
    var dragChanged: (_ paths: [String]) -> Void = { _ in }
    /// Space: toggle Quick Look for the selection.
    var quickLook: () -> Void = {}
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// Finder-like file list backed by `NSTableView` (view-based, so only visible rows are built).
struct FileTableView: NSViewRepresentable {
    /// The folder being shown; when it changes the table scrolls back to the top, like Finder.
    let folderPath: String
    let rows: [FileRow]
    /// Changes only when `rows` changes; the table reloads only then.
    let rowsVersion: Int
    let selection: Set<String>
    let sort: FileSort
    let onSelect: (Set<String>) -> Void
    let onOpen: (FileRow) -> Void
    let onSort: (FileSort) -> Void
    /// A file promise for dragging a row out to Finder (download starts on drop).
    let promise: (FileRow) -> NSFilePromiseProvider?
    /// Finder items dropped on the table (`folder` nil) or onto a folder row.
    let onDropFiles: (_ urls: [URL], _ folder: FileRow?) -> Void
    /// The row whose name is being edited inline, if any.
    var editingPath: String?
    var actions = FileTableActions()
    /// Controls the Quick Look panel while this table is first responder.
    var preview: QuickLookPanelPresenter?
    var rowSize: RowSize = .small
    /// Thumbnails for visible rows (nil = icons only).
    var thumbnails: ThumbnailBinder?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileNSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = rowSize.rowHeight

        for spec in Coordinator.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.key.rawValue))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.key.rawValue, ascending: true)
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.action = #selector(Coordinator.clicked(_:))
        let menu = NSMenu()
        menu.autoenablesItems = false // honour each item's isEnabled
        menu.delegate = context.coordinator
        table.menu = menu
        table.onOpenSelection = { [weak coordinator = context.coordinator] in coordinator?.openSelection() }
        table.onQuickLook = { [weak coordinator = context.coordinator] in coordinator?.parent?.actions.quickLook() }
        table.setAccessibilityLabel("Files")
        // .fileURL for Finder items; the file-promise types so our own rows (dragged as promises) can be
        // dropped onto a folder row of this table to move/copy them.
        table.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        struct ColumnSpec {
            let key: SortKey
            let title: String
            let width: CGFloat
            let minWidth: CGFloat
        }

        static let columns = [
            ColumnSpec(key: .name, title: "Name", width: 320, minWidth: 120),
            ColumnSpec(key: .date, title: "Date Modified", width: 170, minWidth: 90),
            ColumnSpec(key: .size, title: "Size", width: 80, minWidth: 50),
            ColumnSpec(key: .kind, title: "Kind", width: 140, minWidth: 60),
        ]

        weak var table: NSTableView?
        private(set) var parent: FileTableView?
        private var rows: [FileRow] = []
        private var version = -1
        private var folderPath: String?
        private var rowSize: RowSize?
        private var hasLoggedValidate = false
        private var isApplying = false
        private let icons = IconCache()
        /// Path being edited inline, and whether Esc ended the edit.
        private var editing: String?
        /// The field being edited; only its own end-of-editing commits, and only for `editing`.
        private weak var editingField: NSTextField?
        private var editCancelled = false
        /// Rows dragged inside this table (for move/copy onto a folder row).
        private var draggedPaths: [String] = []
        /// Finder's "slow click on a selected name starts rename".
        private var lastClickedPath: String?
        private var pendingRename: Task<Void, Never>?

        func update(with parent: FileTableView) {
            self.parent = parent
            guard let table else { return }
            if let fileTable = table as? FileNSTableView, fileTable.preview !== parent.preview {
                fileTable.preview = parent.preview
                parent.preview?.table = table
            }
            isApplying = true
            defer { isApplying = false }

            let sizeChanged = parent.rowSize != rowSize
            if sizeChanged {
                rowSize = parent.rowSize
                table.rowHeight = parent.rowSize.rowHeight
                Logger.ui.info("rowSize=\(parent.rowSize.rawValue, privacy: .public)")
            }
            if parent.folderPath != folderPath { parent.thumbnails?.unbindAll() }

            // Never reload under an inline edit: the field would be recycled mid-typing.
            if (parent.rowsVersion != version || sizeChanged), editing == nil {
                lastClickedPath = nil // a slow click must not survive a reload or folder change
                pendingRename?.cancel()
                let clock = ContinuousClock()
                let started = clock.now
                rows = parent.rows
                version = parent.rowsVersion
                table.reloadData()
                if parent.folderPath != folderPath {
                    folderPath = parent.folderPath
                    if !rows.isEmpty { table.scrollRowToVisible(0) }
                }
                applySelection(parent.selection, to: table)
                let elapsed = clock.now - started
                Logger.ui.info(
                    "apply rows=\(self.rows.count) mainMs=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)"
                )
            } else {
                applySelection(parent.selection, to: table)
            }

            let descriptor = NSSortDescriptor(key: parent.sort.key.rawValue, ascending: parent.sort.ascending)
            if table.sortDescriptors.first != descriptor {
                table.sortDescriptors = [descriptor]
            }
            syncEditing(with: parent.editingPath, in: table)
        }

        // MARK: Inline rename

        private func syncEditing(with path: String?, in table: NSTableView) {
            guard path != editing else { return }
            // Whatever comes next, end a live edit first without committing it to another row.
            abortCurrentEdit()
            if let path, let row = rows.firstIndex(where: { $0.id == path }) {
                table.scrollRowToVisible(row)
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                      let field = cell.textField else { return }
                editing = path
                editingField = field
                editCancelled = false
                field.isEditable = true
                field.delegate = self
                table.window?.makeFirstResponder(field)
                // Like Finder: select the name without its extension.
                let name = field.stringValue as NSString
                let stemLength = name.pathExtension.isEmpty || rows[row].file.isDirectory
                    ? name.length : name.length - name.pathExtension.count - 1
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: max(0, stemLength))
            }
        }

        /// Ends the current inline edit without committing (the store already moved on).
        private func abortCurrentEdit() {
            guard let field = editingField, let path = editing else { editing = nil; editingField = nil; return }
            editing = nil
            editingField = nil
            field.abortEditing()
            field.isEditable = false
            field.stringValue = (path as NSString).lastPathComponent
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                editCancelled = true
                (control as? NSTextField)?.abortEditing()
                finishEditing(control as? NSTextField)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finishEditing(notification.object as? NSTextField)
        }

        private func finishEditing(_ field: NSTextField?) {
            // Only the field we started editing may commit, and only for the path it was started for.
            guard let path = editing, let field, field === editingField else { return }
            editing = nil
            editingField = nil
            field.isEditable = false
            if editCancelled {
                field.stringValue = (path as NSString).lastPathComponent
                parent?.actions.cancelRename()
            } else {
                parent?.actions.commitRename(path, field.stringValue)
            }
            table?.window?.makeFirstResponder(table)
            // Rows may have changed while editing; apply them now.
            if let parent { update(with: parent) }
        }

        @objc func clicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            let path = rows.indices.contains(row) ? rows[row].id : nil
            defer { lastClickedPath = path }
            pendingRename?.cancel()
            guard let path, path == lastClickedPath, sender.clickedColumn == 0, sender.selectedRowIndexes == [row],
                  parent?.actions.canOperate == true else { return }
            pendingRename = Task { [weak self] in
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.2))
                guard !Task.isCancelled, let self, let table = self.table, self.lastClickedPath == path,
                      table.selectedRowIndexes.count == 1, let selected = table.selectedRowIndexes.first,
                      self.rows.indices.contains(selected), self.rows[selected].id == path else { return }
                self.parent?.actions.beginRename(path)
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let parent else { return }
            let row = table.clickedRow
            var clicked: FileRow?
            if rows.indices.contains(row) {
                clicked = rows[row]
                if !table.selectedRowIndexes.contains(row) {
                    // Like Finder: right-clicking an unselected row selects just that row.
                    table.selectRowIndexes([row], byExtendingSelection: false)
                }
            }
            let selection = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
            for item in parent.actions.menuItems(clicked, clicked == nil ? [] : selection) { menu.addItem(item) }
        }

        private func applySelection(_ selection: Set<String>, to table: NSTableView) {
            let wanted = IndexSet(rows.indices.filter { selection.contains(rows[$0].id) })
            if table.selectedRowIndexes != wanted {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
            }
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier, rows.indices.contains(row) else { return nil }
            let item = rows[row]
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? makeCell(identifier: identifier, withIcon: identifier.rawValue == SortKey.name.rawValue)
            switch SortKey(rawValue: identifier.rawValue) {
            case .name:
                cell.textField?.stringValue = item.name
                // A reused cell shows the system icon at once; the thumbnail (if any) replaces it later.
                cell.imageView?.image = icons.icon(for: item)
                cell.setAccessibilityLabel("\(item.name), \(item.kind)")
                if let nameCell = cell as? FileNameCellView {
                    nameCell.shownPath = item.id
                    nameCell.setIconSize(rowSize?.iconSize ?? 16)
                    parent?.thumbnails?.bind(nameCell, to: item.file)
                }
            case .date:
                cell.textField?.stringValue = item.dateText
            case .size:
                cell.textField?.stringValue = item.sizeText
            case .kind:
                cell.textField?.stringValue = item.kind
            case nil:
                break
            }
            cell.textField?.textColor = item.file.isHidden ? .secondaryLabelColor : .labelColor
            return cell
        }

        func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
            guard let binder = parent?.thumbnails else { return }
            for case let cell as FileNameCellView in rowView.subviews {
                binder.unbind(cell)
                cell.shownPath = nil
            }
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard tableColumn?.identifier.rawValue == SortKey.name.rawValue, rows.indices.contains(row) else { return nil }
            return rows[row].name
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table else { return }
            let paths = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            parent?.onSelect(paths)
        }

        // MARK: Drag & drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard rows.indices.contains(row), !rows[row].file.isSymlink else { return nil }
            return parent?.promise(rows[row])
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            draggedPaths = rowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
            parent?.actions.dragChanged(draggedPaths)
            Logger.transfer.info("promise drag began rows=\(rowIndexes.count)")
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            draggedPaths = []
            parent?.actions.dragChanged([])
        }

        /// ⌥ during a drag narrows the source mask to copy (the cursor shows "+"); that, not the key state at drop
        /// time, decides between move and copy.
        static func isCopy(_ info: any NSDraggingInfo) -> Bool {
            !info.draggingSourceOperationMask.contains(.move)
        }

        /// A valid folder row to move/copy the dragged rows into, or nil.
        private func internalDropTarget(row: Int, operation: NSTableView.DropOperation) -> FileRow? {
            guard parent?.actions.canOperate == true, operation == .on, rows.indices.contains(row) else { return nil }
            let target = rows[row]
            guard target.file.isDirectory, !draggedPaths.isEmpty else { return nil }
            // Not onto one of the dragged rows, and never a folder into itself or its descendant.
            guard !draggedPaths.contains(where: { target.id == $0 || target.id.hasPrefix($0 + "/") }) else { return nil }
            return target
        }

        func tableView(
            _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            if info.draggingSource as? NSTableView === tableView {
                guard internalDropTarget(row: row, operation: dropOperation) != nil else { return [] }
                return Self.isCopy(info) ? .copy : .move
            }
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
                Logger.transfer.info("drop refused: no file URLs on the pasteboard")
                return []
            }
            if !hasLoggedValidate {
                hasLoggedValidate = true
                Logger.transfer.info("drop validate row=\(row) onFolder=\(dropOperation == .on)")
            }
            if dropOperation == .on, rows.indices.contains(row), rows[row].file.isDirectory {
                return .copy // into that folder
            }
            tableView.setDropRow(-1, dropOperation: .on) // the whole table = current folder
            return .copy
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation
        ) -> Bool {
            hasLoggedValidate = false
            if info.draggingSource as? NSTableView === tableView {
                guard let target = internalDropTarget(row: row, operation: dropOperation) else { return false }
                let copy = Self.isCopy(info)
                Logger.ui.info("drop op=\(copy ? "copy" : "move", privacy: .public) count=\(self.draggedPaths.count) dest=\(target.id, privacy: .public)")
                parent?.actions.moveRows(draggedPaths, target.id, copy)
                return true
            }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            Logger.transfer.info("drop accept urls=\(urls.count)")
            guard !urls.isEmpty else { return false }
            let folder = (dropOperation == .on && rows.indices.contains(row) && rows[row].file.isDirectory) ? rows[row] : nil
            parent?.onDropFiles(urls, folder)
            return true
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
            parent?.onSort(FileSort(key: key, ascending: descriptor.ascending))
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            pendingRename?.cancel()
            lastClickedPath = nil
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            parent?.onOpen(rows[row])
        }

        func openSelection() {
            guard let table, table.selectedRowIndexes.count == 1,
                  let index = table.selectedRowIndexes.first, rows.indices.contains(index) else { return }
            parent?.onOpen(rows[index])
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) -> NSTableCellView {
            let cell = withIcon ? FileNameCellView() : NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            var constraints = [
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            ]
            if withIcon, let nameCell = cell as? FileNameCellView {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image)
                cell.imageView = image
                let width = image.widthAnchor.constraint(equalToConstant: 16)
                let height = image.heightAnchor.constraint(equalToConstant: 16)
                nameCell.iconConstraints = [width, height]
                constraints += [
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    width, height,
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ]
            } else {
                constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
            }
            NSLayoutConstraint.activate(constraints)
            return cell
        }
    }
}

/// The Name column's cell: icon or thumbnail plus the name.
final class FileNameCellView: NSTableCellView, ThumbnailTarget {
    var shownPath: String?
    var iconConstraints: [NSLayoutConstraint] = []

    func setIconSize(_ size: CGFloat) {
        for constraint in iconConstraints where constraint.constant != size { constraint.constant = size }
    }

    func showThumbnail(_ image: NSImage) {
        imageView?.image = image
    }
}

/// Table that opens the selection on Return/Enter, like Finder's ⌘↓, and toggles Quick Look on Space.
///
/// Only `keyDown` and the Quick Look panel controller methods are overridden here: overriding the dragging
/// source methods broke drag & drop before (ADB-5).
final class FileNSTableView: NSTableView {
    var onOpenSelection: (() -> Void)?
    var onQuickLook: (() -> Void)?
    weak var preview: QuickLookPanelPresenter?

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter, 49 = Space (without modifiers: Quick Look, like Finder)
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 36 || event.keyCode == 76 {
            onOpenSelection?()
        } else if event.keyCode == 49, modifiers.isEmpty {
            onQuickLook?()
        } else {
            super.keyDown(with: event)
        }
    }

    // QLPreviewPanelController (an informal protocol; AppKit calls these on the main thread).

    /// Whether this table handed the panel to its presenter (cleared in `end`).
    private var controlsPanel = false

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { preview?.wantsPanel == true }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let panel, let preview else { return }
            controlsPanel = true
            preview.begin(panel)
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let panel, controlsPanel else { return }
            controlsPanel = false
            if let preview {
                preview.end(panel)
            } else {
                // The presenter is already gone (browser torn down): the panel must not keep dangling pointers.
                panel.dataSource = nil
                panel.delegate = nil
            }
        }
    }
}

/// System file icons, cached per extension (the lookup is not free and rows are recycled constantly).
@MainActor
final class IconCache {
    private var byKey: [String: NSImage] = [:]

    func icon(for row: FileRow) -> NSImage {
        let key: String
        let type: UTType
        if row.file.isDirectory {
            key = "/folder"
            type = .folder
        } else if row.file.isSymlink {
            key = "/alias"
            type = .aliasFile
        } else {
            let ext = (row.name as NSString).pathExtension.lowercased()
            key = ext
            type = UTType(filenameExtension: ext) ?? .data
        }
        if let cached = byKey[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        byKey[key] = image
        return image
    }
}
