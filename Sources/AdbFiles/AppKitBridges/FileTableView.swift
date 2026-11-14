import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileNSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 22

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
        table.onOpenSelection = { [weak coordinator = context.coordinator] in coordinator?.openSelection() }
        table.setAccessibilityLabel("Files")

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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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
        private var parent: FileTableView?
        private var rows: [FileRow] = []
        private var version = -1
        private var folderPath: String?
        private var isApplying = false
        private let icons = IconCache()

        func update(with parent: FileTableView) {
            self.parent = parent
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }

            if parent.rowsVersion != version {
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
                cell.imageView?.image = icons.icon(for: item)
                cell.setAccessibilityLabel("\(item.name), \(item.kind)")
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

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard tableColumn?.identifier.rawValue == SortKey.name.rawValue, rows.indices.contains(row) else { return nil }
            return rows[row].name
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table else { return }
            let paths = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            parent?.onSelect(paths)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
            parent?.onSort(FileSort(key: key, ascending: descriptor.ascending))
        }

        @objc func doubleClicked(_ sender: NSTableView) {
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
            let cell = NSTableCellView()
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
            if withIcon {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                constraints += [
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
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

/// Table that opens the selection on Return/Enter, like Finder's ⌘↓.
final class FileNSTableView: NSTableView {
    var onOpenSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter
        if event.keyCode == 36 || event.keyCode == 76 {
            onOpenSelection?()
        } else {
            super.keyDown(with: event)
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
