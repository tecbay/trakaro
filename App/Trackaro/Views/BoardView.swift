import AppKit
import SwiftUI
import TrackaroCore
import TrackaroKit

/// The Kanban board: one column per workflow state (or per category across teams).
///
/// Cards drag between and within columns; dropping on a card places the dragged one above it, dropping on empty
/// column space puts it at the end. When an agent moves a card, the board animates it to its new column, unless
/// Reduce Motion is on.
struct BoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var cardSpace
    @State private var dropTarget: DropTarget?

    struct DropTarget: Equatable {
        let column: String
        let before: String?
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(model.columns) { column in
                            BoardColumnView(column: column, cardSpace: cardSpace, dropTarget: $dropTarget)
                                .frame(height: max(geometry.size.height - 24, 200))
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.cursor) { _, cursor in
                    guard let cursor else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(cursor) }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.columns)
        .clipped()
    }
}

private struct BoardColumnView: View {
    @Environment(AppModel.self) private var model
    let column: BoardColumn
    let cardSpace: Namespace.ID
    @Binding var dropTarget: BoardView.DropTarget?

    private var isTargeted: Bool { dropTarget?.column == column.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(column.cards) { card in
                        if dropTarget == BoardView.DropTarget(column: column.id, before: card.id) {
                            InsertionMarker()
                        }
                        BoardCard(card: card, selected: model.selection.contains(card.id), focused: model.cursor == card.id)
                            .matchedGeometryEffect(id: card.id, in: cardSpace)
                            .id(card.id)
                            .onTapGesture { tap(card) }
                            .draggable(card.id) {
                                BoardCard(card: card, selected: false, focused: false).frame(width: 260)
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                dropTarget = nil
                                guard let id = ids.first else { return false }
                                model.drop(id, on: column, before: card.id)
                                return true
                            } isTargeted: { inside in
                                let target = BoardView.DropTarget(column: column.id, before: card.id)
                                if inside { dropTarget = target } else if dropTarget == target { dropTarget = nil }
                            }
                    }
                    if dropTarget == BoardView.DropTarget(column: column.id, before: nil) {
                        InsertionMarker()
                    }
                    if column.cards.isEmpty {
                        Text("No issues")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 284)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentTheme.opacity(0.08) : Color.primary.opacity(0.035))
        )
        .dropDestination(for: String.self) { ids, _ in
            dropTarget = nil
            guard let id = ids.first else { return false }
            model.drop(id, on: column, before: nil)
            return true
        } isTargeted: { inside in
            let target = BoardView.DropTarget(column: column.id, before: nil)
            if inside, dropTarget?.column != column.id { dropTarget = target }
            if !inside, dropTarget == target { dropTarget = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: Symbols.state(column.category))
                .foregroundStyle(Color(nsColor: Theme.stateColor(column.color)))
            Text(column.title).font(.callout.weight(.semibold))
            Text("\(column.cards.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                model.quickCreateStateId = column.stateId
                model.perform(.newIssue)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New issue in \(column.title)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Click selects one card; Command-click adds or removes it from the selection.
    private func tap(_ card: IssueRowItem) {
        if NSEvent.modifierFlags.contains(.command) {
            var ids = model.selection
            if ids.contains(card.id) { ids.remove(card.id) } else { ids.insert(card.id) }
            model.select(ids, cursor: card.id)
        } else {
            model.select([card.id], cursor: card.id)
        }
    }
}

private struct InsertionMarker: View {
    var body: some View {
        Capsule()
            .fill(Color.accentTheme)
            .frame(height: 3)
            .padding(.horizontal, 2)
            .transition(.opacity)
    }
}

struct BoardCard: View {
    let card: IssueRowItem
    let selected: Bool
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                priorityIcon
                Text(card.identifier)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let parent = card.parentIdentifier {
                    Text("› \(parent)").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if let assignee = card.assignee {
                    Image(systemName: card.assigneeIsAgent ? "sparkles" : "person.crop.circle.fill")
                        .foregroundStyle(card.assigneeIsAgent ? Color.agent : Color.secondary)
                        .help(assignee)
                }
            }
            Text(card.title)
                .font(.system(size: Theme.bodySize))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !card.labels.isEmpty || card.dueDate != nil {
                HStack(spacing: 8) {
                    ForEach(card.labels.prefix(3), id: \.self) { label in
                        HStack(spacing: 3) {
                            Circle().fill(Color(nsColor: Theme.stateColor(label.color))).frame(width: 6, height: 6)
                            Text(label.name)
                        }
                    }
                    if let due = card.dueDate {
                        Label(due.description, systemImage: "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if let note = card.note {
                Label(note, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color.agent)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected || focused ? Color.accentTheme : Color.primary.opacity(0.09), lineWidth: selected || focused ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.identifier), \(card.title), \(card.stateName)")
    }

    private var priorityIcon: some View {
        let symbol = Symbols.priority(card.priority)
        return Image(systemName: symbol.name, variableValue: symbol.fill)
            .foregroundStyle(Color(nsColor: Theme.priorityColor(card.priority)))
            .font(.system(size: 11))
            .help(card.priority == .none ? "No priority" : card.priority.name.capitalized)
    }
}
