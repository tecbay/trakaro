import Foundation
import TrackaroCore

/// One kind of constraint in an `IssueFilter`, as the filter bar and the `F` picker show it.
public enum FilterDimension: String, CaseIterable, Sendable {
    /// `category` is set by pages saved as views and by agents ("open issues"); the picker offers statuses instead.
    case text, team, category, status, priority, assignee, label, project

    public var title: String {
        switch self {
        case .text: "Text"
        case .team: "Team"
        case .category: "Status type"
        case .status: "Status"
        case .priority: "Priority"
        case .assignee: "Assignee"
        case .label: "Label"
        case .project: "Project"
        }
    }
}

/// A value the user can switch on or off in a filter. A status option covers every state with that name, so
/// "In Progress" filters across teams in views that span them.
public struct FilterOption: Hashable, Sendable, Identifiable {
    public let dimension: FilterDimension
    public let title: String
    /// Ids for the dimension; priority raw values as text for priority.
    public let values: [String]

    public var id: String { "\(dimension.rawValue).\(values.joined(separator: ","))" }

    public func isOn(in filter: IssueFilter) -> Bool {
        let current = Set(Self.values(of: dimension, in: filter) ?? [])
        return !values.isEmpty && values.allSatisfy(current.contains)
    }

    /// The filter with this option switched: on adds every value, off removes every value.
    public func toggled(in filter: IssueFilter) -> IssueFilter {
        var current = Self.values(of: dimension, in: filter) ?? []
        if isOn(in: filter) {
            current.removeAll(where: values.contains)
        } else {
            current += values.filter { !current.contains($0) }
        }
        return Self.setting(dimension, to: current, in: filter)
    }

    static func values(of dimension: FilterDimension, in filter: IssueFilter) -> [String]? {
        switch dimension {
        case .text: filter.text.map { [$0] }
        case .team: filter.teamIds
        case .category: filter.stateCategories?.map(\.rawValue)
        case .status: filter.stateIds
        case .priority: filter.priorities?.map { String($0.rawValue) }
        case .assignee: filter.assigneeIds
        case .label: filter.labelIds
        case .project: filter.projectIds
        }
    }

    static func setting(_ dimension: FilterDimension, to values: [String], in filter: IssueFilter) -> IssueFilter {
        var filter = filter
        switch dimension {
        case .text: filter.text = values.first
        case .team: filter.teamIds = values
        case .category: filter.stateCategories = values.compactMap(StateCategory.init(rawValue:))
        case .status: filter.stateIds = values
        case .priority: filter.priorities = values.compactMap { Int($0).flatMap(Priority.init(rawValue:)) }
        case .assignee: filter.assigneeIds = values
        case .label: filter.labelIds = values
        case .project: filter.projectIds = values
        }
        return filter.normalized
    }
}

/// What the filter bar shows for one constrained dimension: "Status is In Progress, Todo".
public struct FilterChip: Hashable, Sendable, Identifiable {
    public let dimension: FilterDimension
    public let summary: String

    public var id: String { dimension.rawValue }
}

public enum FilterCatalog {
    /// Every option worth offering where the user is. Inside a team, statuses and labels are that team's; elsewhere
    /// they span every active team and a team option appears when there is more than one.
    public static func options(snapshot: WorkspaceSnapshot, teamId: String?, userId: String?) -> [FilterOption] {
        let teams = snapshot.teams.filter { $0.archivedAt == nil && (teamId == nil || $0.id == teamId) }
        let teamIds = Set(teams.map(\.id))
        var options: [FilterOption] = []

        if teamId == nil, teams.count > 1 {
            options += teams.map { FilterOption(dimension: .team, title: $0.name, values: [$0.id]) }
        }
        var stateNames: [String] = []
        var stateIds: [String: [String]] = [:]
        for state in snapshot.states where teamIds.contains(state.teamId) {
            if stateIds[state.name] == nil { stateNames.append(state.name) }
            stateIds[state.name, default: []].append(state.id)
        }
        options += stateNames.map { FilterOption(dimension: .status, title: $0, values: stateIds[$0] ?? []) }
        options += [Priority.urgent, .high, .medium, .low, .none].map {
            FilterOption(dimension: .priority, title: $0 == .none ? "No priority" : $0.name.capitalized, values: [String($0.rawValue)])
        }
        let people = snapshot.members.filter { $0.kind != .system }.sorted { lhs, _ in lhs.id == userId }
        options.append(FilterOption(dimension: .assignee, title: "No assignee", values: [IssueFilter.unset]))
        options += people.map {
            FilterOption(dimension: .assignee, title: $0.id == userId ? "\($0.name) (you)" : $0.name, values: [$0.id])
        }
        options += snapshot.labels.filter { $0.teamId == nil || teamIds.contains($0.teamId ?? "") }.map {
            FilterOption(dimension: .label, title: $0.name, values: [$0.id])
        }
        let projects = snapshot.projects.filter { $0.archivedAt == nil }
        if !projects.isEmpty {
            options.append(FilterOption(dimension: .project, title: "No project", values: [IssueFilter.unset]))
            options += projects.map { FilterOption(dimension: .project, title: $0.name, values: [$0.id]) }
        }
        return options
    }

    /// One chip per constrained dimension, in a fixed order, naming values the way the pickers do.
    public static func chips(_ filter: IssueFilter, snapshot: WorkspaceSnapshot, userId: String?) -> [FilterChip] {
        let filter = filter.normalized
        return FilterDimension.allCases.compactMap { dimension in
            guard let values = FilterOption.values(of: dimension, in: filter) else { return nil }
            if dimension == .category, let summary = categorySummary(filter.stateCategories ?? []) {
                return FilterChip(dimension: dimension, summary: summary)
            }
            let names = unique(values.map { name(of: $0, dimension: dimension, snapshot: snapshot, userId: userId) })
            return FilterChip(dimension: dimension, summary: names.joined(separator: ", "))
        }
    }

    /// The filter without one dimension.
    public static func clearing(_ dimension: FilterDimension, in filter: IssueFilter) -> IssueFilter {
        FilterOption.setting(dimension, to: [], in: filter)
    }

    private static func name(of value: String, dimension: FilterDimension, snapshot: WorkspaceSnapshot, userId: String?) -> String {
        switch dimension {
        case .text: return "“\(value)”"
        case .team: return snapshot.teamsById[value]?.name ?? "Unknown team"
        case .category: return StateCategory(rawValue: value)?.displayName ?? value
        case .status: return snapshot.statesById[value]?.name ?? "Unknown status"
        case .priority:
            guard let priority = Int(value).flatMap(Priority.init(rawValue:)) else { return value }
            return priority == .none ? "No priority" : priority.name.capitalized
        case .assignee:
            if value == IssueFilter.unset { return "No assignee" }
            if value == userId { return "Me" }
            return snapshot.membersById[value]?.name ?? "Unknown member"
        case .label: return snapshot.labelsById[value]?.name ?? "Unknown label"
        case .project:
            return value == IssueFilter.unset ? "No project" : snapshot.projectsById[value]?.name ?? "Unknown project"
        }
    }

    private static func categorySummary(_ categories: [StateCategory]) -> String? {
        let set = Set(categories)
        if set == Set(StateCategory.allCases.filter(\.isOpen)) { return "Open" }
        if set == [.completed, .canceled] { return "Closed" }
        return nil
    }

    private static func unique(_ names: [String]) -> [String] {
        names.reduce(into: []) { list, name in if !list.contains(name) { list.append(name) } }
    }
}
