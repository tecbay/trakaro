import Foundation
import TrackaroCore

public struct LabelChip: Hashable, Sendable {
    public let name: String
    public let color: String
}

/// Everything one list row draws, resolved to display values once so cells never query.
public struct IssueRowItem: Hashable, Sendable, Identifiable {
    public let id: String
    public let identifier: String
    public let title: String
    public let priority: Priority
    public let category: StateCategory
    public let stateName: String
    public let stateColor: String
    public let labels: [LabelChip]
    public let assignee: String?
    public let assigneeIsAgent: Bool
    public let parentIdentifier: String?
    public let dueDate: CalendarDate?
    /// Free text on the right edge, such as "Claude Code · 2 min ago" in the agent activity list.
    public let note: String?
}

public struct GroupHeader: Hashable, Sendable {
    public let id: String
    public let title: String
    public let category: StateCategory
    public let color: String
    public let count: Int
}

public enum ListRow: Hashable, Sendable {
    case group(GroupHeader)
    case issue(IssueRowItem)

    public var issueId: String? {
        if case let .issue(item) = self { item.id } else { nil }
    }
}

public enum ListGrouping: Sendable {
    /// One group per workflow state, in workflow order. For lists within one team.
    case state
    /// One group per state category. For lists that span teams, whose state names differ.
    case category
    case none
}

public enum IssueRowBuilder {
    public static func item(
        _ issue: Issue, snapshot: WorkspaceSnapshot, labelIds: [String], parentIdentifier: String?, note: String? = nil
    ) -> IssueRowItem {
        let state = snapshot.statesById[issue.stateId]
        let assignee = issue.assigneeId.flatMap { snapshot.membersById[$0] }
        return IssueRowItem(
            id: issue.id,
            identifier: issue.identifier,
            title: issue.title,
            priority: issue.priority,
            category: state?.category ?? .backlog,
            stateName: state?.name ?? "",
            stateColor: state?.color ?? "#95A2B3",
            labels: labelIds.compactMap { snapshot.labelsById[$0] }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { LabelChip(name: $0.name, color: $0.color) },
            assignee: assignee?.name,
            assigneeIsAgent: assignee?.kind == .agent,
            parentIdentifier: parentIdentifier,
            dueDate: issue.dueDate,
            note: note
        )
    }

    /// Rows for a list: group headers followed by their issues. Issues keep their incoming order within a group.
    public static func rows(
        _ issues: [Issue], snapshot: WorkspaceSnapshot, labelIds: [String: [String]],
        parentIdentifiers: [String: String], grouping: ListGrouping, notes: [String: String] = [:]
    ) -> [ListRow] {
        let items = issues.map {
            item($0, snapshot: snapshot, labelIds: labelIds[$0.id] ?? [], parentIdentifier: $0.parentId.flatMap { parentIdentifiers[$0] }, note: notes[$0.id])
        }
        switch grouping {
        case .none:
            return items.map(ListRow.issue)
        case .state:
            var buckets: [String: [IssueRowItem]] = [:]
            for (issue, item) in zip(issues, items) { buckets[issue.stateId, default: []].append(item) }
            let orderedStates = snapshot.states.filter { buckets[$0.id] != nil }
                .sorted { ($0.teamId, $0.position) < ($1.teamId, $1.position) }
            return orderedStates.flatMap { state -> [ListRow] in
                let members = buckets[state.id] ?? []
                let header = GroupHeader(id: state.id, title: state.name, category: state.category, color: state.color, count: members.count)
                return [.group(header)] + members.map(ListRow.issue)
            }
        case .category:
            var buckets: [StateCategory: [IssueRowItem]] = [:]
            for item in items { buckets[item.category, default: []].append(item) }
            return StateCategory.allCases.compactMap { category -> [ListRow]? in
                guard let members = buckets[category] else { return nil }
                let color = members.first?.stateColor ?? "#95A2B3"
                let header = GroupHeader(id: category.rawValue, title: category.displayName, category: category, color: color, count: members.count)
                return [.group(header)] + members.map(ListRow.issue)
            }.flatMap { $0 }
        }
    }
}

extension StateCategory {
    public var displayName: String {
        switch self {
        case .triage: "Triage"
        case .backlog: "Backlog"
        case .unstarted: "Todo"
        case .started: "In Progress"
        case .review: "In Review"
        case .completed: "Done"
        case .canceled: "Canceled"
        }
    }
}
