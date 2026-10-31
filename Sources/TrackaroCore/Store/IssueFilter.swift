import Foundation

/// The filters set on top of a list, and the document a saved view stores as JSON.
///
/// Each dimension means "any of these values" and dimensions combine with AND. In `assigneeIds` and `projectIds`,
/// `IssueFilter.unset` matches issues with no assignee or no project. Applying a filter to a query narrows it and
/// never widens it, so a filter on "My issues" can only ever show fewer of your issues.
public struct IssueFilter: Codable, Hashable, Sendable {
    public static let unset = "none"

    public var text: String?
    public var teamIds: [String]?
    public var stateIds: [String]?
    public var stateCategories: [StateCategory]?
    public var priorities: [Priority]?
    public var assigneeIds: [String]?
    public var labelIds: [String]?
    public var projectIds: [String]?

    public init(
        text: String? = nil, teamIds: [String]? = nil, stateIds: [String]? = nil, stateCategories: [StateCategory]? = nil,
        priorities: [Priority]? = nil, assigneeIds: [String]? = nil, labelIds: [String]? = nil, projectIds: [String]? = nil
    ) {
        self.text = text
        self.teamIds = teamIds
        self.stateIds = stateIds
        self.stateCategories = stateCategories
        self.priorities = priorities
        self.assigneeIds = assigneeIds
        self.labelIds = labelIds
        self.projectIds = projectIds
    }

    /// Blank text and empty lists dropped, so turning off a dimension's last value removes the dimension.
    public var normalized: IssueFilter {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return IssueFilter(
            text: trimmed?.isEmpty == false ? trimmed : nil,
            teamIds: Self.nonEmpty(teamIds), stateIds: Self.nonEmpty(stateIds), stateCategories: Self.nonEmpty(stateCategories),
            priorities: Self.nonEmpty(priorities), assigneeIds: Self.nonEmpty(assigneeIds), labelIds: Self.nonEmpty(labelIds),
            projectIds: Self.nonEmpty(projectIds)
        )
    }

    public var isEmpty: Bool { normalized == IssueFilter() }

    /// How many dimensions are constrained, text included.
    public var count: Int {
        let filter = normalized
        let dimensions: [Bool] = [
            filter.text != nil, filter.teamIds != nil, filter.stateIds != nil, filter.stateCategories != nil,
            filter.priorities != nil, filter.assigneeIds != nil, filter.labelIds != nil, filter.projectIds != nil,
        ]
        return dimensions.filter { $0 }.count
    }

    /// The query narrowed by this filter.
    public func applied(to base: IssueQuery) -> IssueQuery {
        let filter = normalized
        var query = base
        if let text = filter.text {
            query.text = [base.text, text].compactMap { $0 }.joined(separator: " ")
        }
        query.teamIds = Self.intersect(base.teamIds, filter.teamIds)
        query.stateIds = Self.intersect(base.stateIds, filter.stateIds)
        query.stateCategories = Self.intersect(base.stateCategories, filter.stateCategories)
        query.priorities = Self.intersect(base.priorities, filter.priorities)
        query.labelIds = Self.intersect(base.labelIds, filter.labelIds)
        query.assignee = ReferenceFilter.intersect(base.assignee, filter.assigneeIds.map(ReferenceFilter.init(values:)))
        query.project = ReferenceFilter.intersect(base.project, filter.projectIds.map(ReferenceFilter.init(values:)))
        return query
    }

    /// One filter that matches what applying both would: used to save a page plus its filters as a view.
    public func narrowed(by other: IssueFilter) -> IssueFilter {
        let lhs = normalized
        let rhs = other.normalized
        let text = [lhs.text, rhs.text].compactMap { $0 }.joined(separator: " ")
        return IssueFilter(
            text: text.isEmpty ? nil : text,
            teamIds: Self.intersect(lhs.teamIds, rhs.teamIds), stateIds: Self.intersect(lhs.stateIds, rhs.stateIds),
            stateCategories: Self.intersect(lhs.stateCategories, rhs.stateCategories),
            priorities: Self.intersect(lhs.priorities, rhs.priorities), assigneeIds: Self.intersect(lhs.assigneeIds, rhs.assigneeIds),
            labelIds: Self.intersect(lhs.labelIds, rhs.labelIds), projectIds: Self.intersect(lhs.projectIds, rhs.projectIds)
        )
    }

    /// Adds the value when absent and removes it when present.
    public static func toggling<Value: Equatable>(_ value: Value, in values: [Value]?) -> [Value]? {
        var values = values ?? []
        if let index = values.firstIndex(of: value) { values.remove(at: index) } else { values.append(value) }
        return values.isEmpty ? nil : values
    }

    // MARK: JSON

    public init(json: String) throws {
        do {
            self = try JSONDecoder().decode(IssueFilter.self, from: Data(json.utf8)).normalized
        } catch {
            throw TrackaroError.invalid(field: "filter", message: "The saved filter is not valid JSON for a view: \(error.localizedDescription)")
        }
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(normalized) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func nonEmpty<Value>(_ values: [Value]?) -> [Value]? {
        guard let values, !values.isEmpty else { return nil }
        return values
    }

    private static func intersect<Value: Hashable>(_ lhs: [Value]?, _ rhs: [Value]?) -> [Value]? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let kept = Set(rhs)
        return lhs.filter(kept.contains)
    }
}

extension SavedView {
    /// The stored filter. Writes validate it, so only a hand-edited database can make this fall back to no filter.
    public var issueFilter: IssueFilter {
        (try? IssueFilter(json: filter)) ?? IssueFilter()
    }
}
