import AppKit
import SwiftUI

struct ReorderRow: Equatable {
    let id: String
    let title: String
    let subtitle: String
}

/// 드래그 앤 드롭으로 순서를 바꾸는 목록. SwiftUI List 의 onMove 가 macOS 에서 매끄럽지 않아 NSTableView 로 감쌌다.
struct ReorderableTable: NSViewRepresentable {
    let rows: [ReorderRow]
    /// 순서가 바뀔 때마다 새 순서의 id 목록으로 호출된다.
    let onMove: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(rows: rows, onMove: onMove) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: Coordinator.columnID))
        table.headerView = nil
        table.rowHeight = 32
        table.style = .plain
        table.allowsEmptySelection = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([Coordinator.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onMove = onMove
        guard c.rows != rows else { return }
        c.rows = rows
        c.table?.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("row")
        static let rowType = NSPasteboard.PasteboardType("kei.desk.reorder-row")

        var rows: [ReorderRow]
        var onMove: ([String]) -> Void
        weak var table: NSTableView?

        init(rows: [ReorderRow], onMove: @escaping ([String]) -> Void) {
            self.rows = rows
            self.onMove = onMove
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage())
            grip.contentTintColor = .secondaryLabelColor
            let title = NSTextField(labelWithString: rows[row].title)
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let subtitle = NSTextField(labelWithString: rows[row].subtitle)
            subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitle.textColor = .secondaryLabelColor

            let stack = NSStackView(views: [grip, title, subtitle])
            stack.spacing = 8
            let cell = NSTableCellView()
            cell.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let item = NSPasteboardItem()
            item.setString(String(row), forType: Self.rowType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource as? NSTableView === tableView else { return [] }
            // 행 위에 놓는 것도 그 행 앞에 놓는 것으로 본다.
            if op == .on { tableView.setDropRow(row, dropOperation: .above) }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
                  let from = Int(text), rows.indices.contains(from) else { return false }
            let to = row > from ? row - 1 : row
            guard to != from else { return false }

            rows.insert(rows.remove(at: from), at: to)
            tableView.beginUpdates()
            tableView.moveRow(at: from, to: to)
            tableView.endUpdates()
            onMove(rows.map(\.id))
            return true
        }
    }
}
