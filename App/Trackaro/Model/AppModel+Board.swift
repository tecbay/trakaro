import Foundation
import TrackaroCore
import TrackaroKit

/// Kanban behaviour: moving the cursor between cards and columns, dropping cards, and stepping status.
extension AppModel {
    /// Where the cursor's card sits, as column index and position in that column.
    private var cursorPosition: (column: Int, card: Int)? {
        guard let cursor else { return nil }
        for (columnIndex, column) in columns.enumerated() {
            if let cardIndex = column.cards.firstIndex(where: { $0.id == cursor }) { return (columnIndex, cardIndex) }
        }
        return nil
    }

    /// Up and down stay inside the cursor's column. With no cursor, start at the first card on the board.
    func moveCardCursor(by offset: Int) {
        guard let position = cursorPosition else {
            if let first = columns.first(where: { !$0.cards.isEmpty })?.cards.first { select([first.id], cursor: first.id) }
            return
        }
        let cards = columns[position.column].cards
        let target = min(max(position.card + offset, 0), cards.count - 1)
        select([cards[target].id], cursor: cards[target].id)
    }

    /// Left and right jump to the nearest non-empty column in that direction, keeping the row where possible.
    func moveColumnCursor(by offset: Int) {
        guard let position = cursorPosition else {
            moveCardCursor(by: 0)
            return
        }
        var index = position.column + offset
        while columns.indices.contains(index) {
            let cards = columns[index].cards
            if !cards.isEmpty {
                let card = cards[min(position.card, cards.count - 1)]
                select([card.id], cursor: card.id)
                return
            }
            index += offset
        }
    }

    /// Steps the targets one workflow state forward or back within each issue's own team.
    func stepStatus(by offset: Int) {
        guard let snapshot else { return }
        edit(offset > 0 ? "Move to next status" : "Move to previous status", on: targets) { issue in
            let states = snapshot.states(ofTeam: issue.teamId).sorted { $0.position < $1.position }
            guard let index = states.firstIndex(where: { $0.id == issue.stateId }) else { return nil }
            let next = index + offset
            guard states.indices.contains(next) else { return nil }
            return IssuePatch(stateId: states[next].id)
        }
    }

    /// A card dropped on a column, above `beforeCard` or at the end when nil. Records an undo step for the
    /// status change; the new position itself is not undoable.
    func drop(_ issueId: String, on column: BoardColumn, before beforeCard: String?) {
        guard let store, let user, let snapshot else { return }
        do {
            let issue = try store.issue(issueId)
            guard let target = BoardDrop.targetState(for: issue, column: column, snapshot: snapshot) else {
                showToast("\(issue.identifier) belongs to another team's workflow", isError: true)
                return
            }
            let move = BoardDrop.move(issue: issue, target: target, column: column, beforeCard: beforeCard)
            let change = try store.moveIssue(issue.id, move, by: user.id)
            history.record(EditBatch(label: "Move card", edits: [IssueEdit(original: issue, updated: change.issue, changed: change.changed)]))
            reloadAll()
            select([issue.id], cursor: issue.id)
        } catch {
            showError(error)
            reloadAll()
        }
    }
}
