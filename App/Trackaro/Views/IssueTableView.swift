import AppKit
import SwiftUI
import TrackaroCore
import TrackaroKit

/// The issue list, as an `NSTableView`. AppKit reuses a screenful of cell views no matter how many rows there
/// are, which keeps thousands of issues smooth where a SwiftUI `List` would not be.
///
/// Rows only reload when `version` changes; selection is pushed in and out without reloading.
struct IssueTableView: NSViewRepresentable {
    let rows: [ListRow]
    let version: Int
    let selection: Set<String>
    let cursor: String?
    let onSelect: (Set<String>, String?) -> Void
    let onOpen: (String) -> Void
    let onCommand: (AppCommand) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = false
        table.floatsGroupRows = true
        table.focusRingType = .none
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: .init("issue"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.menu = context.coordinator.contextMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        if coordinator.version != version {
            coordinator.version = version
            coordinator.rows = rows
            coordinator.indexById = Dictionary(uniqueKeysWithValues: rows.enumerated().compactMap { index, row in row.issueId.map { ($0, index) } })
            table.reloadData()
        }
        coordinator.applySelection(selection, cursor: cursor)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: IssueTableView
        weak var table: NSTableView?
        var rows: [ListRow] = []
        var indexById: [String: Int] = [:]
        var version = -1
        private var applyingSelection = false
        private var lastScrolledCursor: String?

        init(_ parent: IssueTableView) {
            self.parent = parent
        }

        func applySelection(_ ids: Set<String>, cursor: String?) {
            guard let table else { return }
            let wanted = IndexSet(ids.compactMap { indexById[$0] })
            if table.selectedRowIndexes != wanted {
                applyingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                applyingSelection = false
            }
            if let cursor, cursor != lastScrolledCursor, let row = indexById[cursor] {
                table.scrollRowToVisible(row)
            }
            lastScrolledCursor = cursor
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .group = rows[row] { true } else { false }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if case .group = rows[row] { Theme.groupRowHeight } else { Theme.rowHeight }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows[row].issueId != nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch rows[row] {
            case let .group(header):
                let cell = tableView.makeView(withIdentifier: GroupCell.identifier, owner: nil) as? GroupCell ?? GroupCell()
                cell.configure(header)
                return cell
            case let .issue(item):
                let cell = tableView.makeView(withIdentifier: IssueCell.identifier, owner: nil) as? IssueCell ?? IssueCell()
                cell.configure(item)
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].issueId : nil })
            let clicked = table.clickedRow >= 0 ? rows[table.clickedRow].issueId : nil
            let cursor = clicked ?? (ids.count == 1 ? ids.first : (table.selectedRow >= 0 ? rows[table.selectedRow].issueId : nil))
            lastScrolledCursor = cursor
            parent.onSelect(ids, cursor)
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, let id = rows[table.clickedRow].issueId else { return }
            parent.onOpen(id)
        }

        func contextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        /// Right-clicking a row outside the selection selects it first, as Finder does.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, let id = rows[table.clickedRow].issueId else { return }
            if !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
                parent.onSelect([id], id)
            }
            let entries: [AppCommand?] = [.setStatus, .setPriority, .setAssignee, .setLabels, .setEstimate, nil, .assignToMe, .copyIdentifier, nil, .archive]
            for entry in entries {
                guard let command = entry else {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: command.definition.title, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command.rawValue
                menu.addItem(item)
            }
        }

        @objc func runMenuCommand(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let command = AppCommand(rawValue: raw) else { return }
            parent.onCommand(command)
        }
    }
}

// MARK: - Cells

final class IssueCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("IssueCell")

    private let priorityIcon = NSImageView()
    private let identifierLabel = NSTextField(labelWithString: "")
    private let stateIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let parentLabel = NSTextField(labelWithString: "")
    private let labelsLabel = NSTextField(labelWithString: "")
    private let dueLabel = NSTextField(labelWithString: "")
    private let assigneeIcon = NSImageView()
    private let trailingLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        identifierLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        identifierLabel.textColor = .secondaryLabelColor
        identifierLabel.alignment = .left
        titleLabel.font = .systemFont(ofSize: Theme.bodySize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for label in [parentLabel, labelsLabel, dueLabel, trailingLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        labelsLabel.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        for icon in [priorityIcon, stateIcon, assigneeIcon] {
            icon.imageScaling = .scaleProportionallyDown
            icon.setContentHuggingPriority(.required, for: .horizontal)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [priorityIcon, identifierLabel, stateIcon, titleLabel, parentLabel, spacer, labelsLabel, dueLabel, assigneeIcon, trailingLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(10, after: identifierLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            priorityIcon.widthAnchor.constraint(equalToConstant: 16),
            stateIcon.widthAnchor.constraint(equalToConstant: 16),
            identifierLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ item: IssueRowItem) {
        let priority = Symbols.priority(item.priority)
        priorityIcon.image = Symbols.image(priority.name, fill: priority.fill, size: 12)
        priorityIcon.contentTintColor = Theme.priorityColor(item.priority)
        priorityIcon.toolTip = item.priority == .none ? "No priority" : item.priority.name.capitalized

        identifierLabel.stringValue = item.identifier
        stateIcon.image = Symbols.image(Symbols.state(item.category), size: 13, weight: .medium)
        stateIcon.contentTintColor = Theme.stateColor(item.stateColor)
        stateIcon.toolTip = item.stateName
        titleLabel.stringValue = item.title

        parentLabel.stringValue = item.parentIdentifier.map { "› \($0)" } ?? ""
        parentLabel.isHidden = item.parentIdentifier == nil

        labelsLabel.attributedStringValue = Self.labelText(item.labels)
        labelsLabel.isHidden = item.labels.isEmpty

        dueLabel.stringValue = item.dueDate.map { "Due \($0.description)" } ?? ""
        dueLabel.isHidden = item.dueDate == nil

        if let assignee = item.assignee {
            assigneeIcon.image = Symbols.image(item.assigneeIsAgent ? "sparkles" : "person.crop.circle.fill", size: 13)
            assigneeIcon.contentTintColor = item.assigneeIsAgent ? Theme.agent : .tertiaryLabelColor
            assigneeIcon.toolTip = assignee
            assigneeIcon.isHidden = false
        } else {
            assigneeIcon.isHidden = true
        }
        trailingLabel.stringValue = item.note ?? item.assignee ?? ""
        trailingLabel.isHidden = trailingLabel.stringValue.isEmpty
        trailingLabel.textColor = item.note != nil ? Theme.agent : .secondaryLabelColor
    }

    private static func labelText(_ labels: [LabelChip]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, label) in labels.prefix(3).enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "  ")) }
            text.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: Theme.stateColor(label.color), .font: NSFont.systemFont(ofSize: 9)]))
            text.append(NSAttributedString(string: label.name, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
        }
        if labels.count > 3 {
            text.append(NSAttributedString(string: "  +\(labels.count - 3)", attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
        }
        return text
    }
}

final class GroupCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GroupCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, title, count])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ header: GroupHeader) {
        icon.image = Symbols.image(Symbols.state(header.category), size: 12, weight: .medium)
        icon.contentTintColor = Theme.stateColor(header.color)
        title.stringValue = header.title
        count.stringValue = "\(header.count)"
    }
}
