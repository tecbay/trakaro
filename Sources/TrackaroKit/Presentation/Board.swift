import Foundation
import TrackaroCore

/// One Kanban column: a workflow state of one team, or a state category across teams.
public struct BoardColumn: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let category: StateCategory
    public let color: String
    /// The state this column is. Nil for a category column, whose cards come from several teams' states.
    public let stateId: String?
    public let cards: [IssueRowItem]
}

public enum BoardBuilder {
    /// Categories a cross-team board always shows, so there is somewhere to drop a card even when empty.
    public static let coreCategories: [StateCategory] = [.backlog, .unstarted, .started, .review, .completed]

    /// One column per state, in workflow order, including empty states so cards can be dropped into them.
    public static func stateColumns(_ items: [IssueRowItem], states: [WorkflowState]) -> [BoardColumn] {
        let byState = Dictionary(grouping: items, by: \.stateId)
        return states.sorted { $0.position < $1.position }.map { state in
            BoardColumn(id: state.id, title: state.name, category: state.category, color: state.color,
                        stateId: state.id, cards: byState[state.id] ?? [])
        }
    }

    /// One column per category, for boards spanning teams. The core categories always appear; triage and
    /// canceled appear only when they hold cards.
    public static func categoryColumns(_ items: [IssueRowItem], snapshot: WorkspaceSnapshot) -> [BoardColumn] {
        let byCategory = Dictionary(grouping: items, by: \.category)
        return StateCategory.allCases.compactMap { category in
            let cards = byCategory[category] ?? []
            guard coreCategories.contains(category) || !cards.isEmpty else { return nil }
            let color = snapshot.states.filter { $0.category == category }.min { $0.position < $1.position }?.color ?? "#95A2B3"
            return BoardColumn(id: category.rawValue, title: category.displayName, category: category, color: color, stateId: nil, cards: cards)
        }
    }
}

/// Where a dropped card goes.
public enum BoardDrop {
    /// The state an issue lands in when dropped on `column`. A state column must belong to the issue's team.
    /// A category column keeps the issue's state if it is already in that category, otherwise picks the first
    /// state of that category in the issue's own team.
    public static func targetState(for issue: Issue, column: BoardColumn, snapshot: WorkspaceSnapshot) -> WorkflowState? {
        if let stateId = column.stateId {
            guard let state = snapshot.statesById[stateId], state.teamId == issue.teamId else { return nil }
            return state
        }
        if let current = snapshot.statesById[issue.stateId], current.category == column.category { return current }
        return snapshot.states(ofTeam: issue.teamId)
            .filter { $0.category == column.category }
            .min { $0.position < $1.position }
    }

    /// The store move for a drop: land in `target`, directly above `beforeCard`, or at the end of the column
    /// when dropped on empty space. Neighbours from another team or state are ignored, since manual order only
    /// exists within one team's state.
    public static func move(
        issue: Issue, target: WorkflowState, column: BoardColumn, beforeCard: String?
    ) -> IssueMove {
        let sameColumn = column.cards.filter { $0.stateId == target.id && $0.id != issue.id }
        var move = IssueMove(stateId: target.id == issue.stateId ? nil : target.id)
        if let beforeCard, beforeCard != issue.id, sameColumn.contains(where: { $0.id == beforeCard }) {
            move.beforeIssue = beforeCard
        } else if beforeCard == nil, let last = sameColumn.last {
            move.afterIssue = last.id
        }
        return move
    }
}
