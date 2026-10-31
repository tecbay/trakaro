import Foundation
import GRDB

/// Matches a nullable reference column: "not set", "one of these ids", or either.
public enum ReferenceFilter: Sendable, Equatable {
    case none
    case anyOf([String])
    case noneOrAnyOf([String])

    /// From filter values, where `IssueFilter.unset` stands for "not set".
    public init(values: [String]) {
        self = Self.make(ids: values.filter { $0 != IssueFilter.unset }, none: values.contains(IssueFilter.unset))
    }

    /// Rows both filters accept. Nil means unconstrained.
    public static func intersect(_ lhs: ReferenceFilter?, _ rhs: ReferenceFilter?) -> ReferenceFilter? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let kept = Set(rhs.parts.ids)
        return make(ids: lhs.parts.ids.filter(kept.contains), none: lhs.parts.none && rhs.parts.none)
    }

    var parts: (ids: [String], none: Bool) {
        switch self {
        case .none: ([], true)
        case let .anyOf(ids): (ids, false)
        case let .noneOrAnyOf(ids): (ids, true)
        }
    }

    private static func make(ids: [String], none: Bool) -> ReferenceFilter {
        guard none else { return .anyOf(ids) }
        return ids.isEmpty ? .none : .noneOrAnyOf(ids)
    }
}

/// A filtered, ordered, paged issue listing. Every nil property means "no constraint".
public struct IssueQuery: Sendable, Equatable {
    public enum Order: String, Sendable, CaseIterable {
        /// Board order: workflow position, then manual position within each state.
        case manual
        /// Urgent first, no priority last, most recently updated first within a priority.
        case priority
        case updated
        case created
        /// Earliest due date first, undated last.
        case due
        /// Best text match first. Falls back to manual order when there is no text.
        case relevance
    }

    public var text: String?
    /// Only these issues. The app uses it to filter a list it built some other way, such as recent agent changes.
    public var issueIds: [String]?
    public var teamIds: [String]?
    public var stateIds: [String]?
    public var stateCategories: [StateCategory]?
    public var assignee: ReferenceFilter?
    /// Issues carrying at least one of these labels.
    public var labelIds: [String]?
    public var project: ReferenceFilter?
    public var cycle: ReferenceFilter?
    public var parentId: String?
    public var priorities: [Priority]?
    public var includeArchived: Bool
    /// False hides issues that have a parent.
    public var includeSubIssues: Bool
    public var order: Order
    public var limit: Int
    public var offset: Int

    public init(
        text: String? = nil, issueIds: [String]? = nil, teamIds: [String]? = nil, stateIds: [String]? = nil, stateCategories: [StateCategory]? = nil,
        assignee: ReferenceFilter? = nil, labelIds: [String]? = nil, project: ReferenceFilter? = nil,
        cycle: ReferenceFilter? = nil, parentId: String? = nil, priorities: [Priority]? = nil,
        includeArchived: Bool = false, includeSubIssues: Bool = true, order: Order = .manual, limit: Int = 50, offset: Int = 0
    ) {
        self.text = text
        self.issueIds = issueIds
        self.teamIds = teamIds
        self.stateIds = stateIds
        self.stateCategories = stateCategories
        self.assignee = assignee
        self.labelIds = labelIds
        self.project = project
        self.cycle = cycle
        self.parentId = parentId
        self.priorities = priorities
        self.includeArchived = includeArchived
        self.includeSubIssues = includeSubIssues
        self.order = order
        self.limit = limit
        self.offset = offset
    }
}

public struct IssuePage: Sendable, Equatable {
    public let issues: [Issue]
    /// Offset of the next page, or nil when this is the last one.
    public let nextOffset: Int?
}

public struct CycleProgress: Sendable, Equatable {
    public let cycle: Cycle
    public let issueCount: Int
    public let countByCategory: [StateCategory: Int]
    public let totalEstimate: Int
    public let completedEstimate: Int

    public var completedCount: Int { countByCategory[.completed] ?? 0 }
    public var canceledCount: Int { countByCategory[.canceled] ?? 0 }
    public var openCount: Int { issueCount - completedCount - canceledCount }
}

extension TrackaroStore {
    /// Large enough for the app to hold a whole team in one list; the MCP layer applies its own smaller cap.
    public static let maxPageSize = 10_000

    public func queryIssues(_ query: IssueQuery) throws -> IssuePage {
        let limit = min(max(query.limit, 1), Self.maxPageSize)
        let offset = max(query.offset, 0)
        let pattern = query.text.flatMap(Self.ftsPattern)
        if query.text != nil, pattern == nil { return IssuePage(issues: [], nextOffset: nil) }

        var joins = ["JOIN workflowState ON workflowState.id = issue.stateId"]
        var conditions: [String] = []
        var arguments: [any DatabaseValueConvertible] = []

        if let pattern {
            joins.append("JOIN issueSearch ON issueSearch.rowid = issue.seq")
            conditions.append("issueSearch MATCH ?")
            arguments.append(pattern)
        }
        if !query.includeArchived { conditions.append("issue.archivedAt IS NULL") }
        if !query.includeSubIssues { conditions.append("issue.parentId IS NULL") }
        if let ids = query.issueIds { conditions.append(Self.membership("issue.id", ids, &arguments)) }
        if let ids = query.teamIds { conditions.append(Self.membership("issue.teamId", ids, &arguments)) }
        if let ids = query.stateIds { conditions.append(Self.membership("issue.stateId", ids, &arguments)) }
        if let categories = query.stateCategories {
            conditions.append(Self.membership("workflowState.category", categories.map(\.rawValue), &arguments))
        }
        if let priorities = query.priorities {
            conditions.append(Self.membership("issue.priority", priorities.map(\.rawValue), &arguments))
        }
        if let filter = query.assignee { conditions.append(Self.reference("issue.assigneeId", filter, &arguments)) }
        if let filter = query.project { conditions.append(Self.reference("issue.projectId", filter, &arguments)) }
        if let filter = query.cycle { conditions.append(Self.reference("issue.cycleId", filter, &arguments)) }
        if let parentId = query.parentId {
            conditions.append("issue.parentId = ?")
            arguments.append(parentId)
        }
        if let labelIds = query.labelIds {
            let inner = Self.membership("issueLabel.labelId", labelIds, &arguments)
            conditions.append("EXISTS (SELECT 1 FROM issueLabel WHERE issueLabel.issueId = issue.id AND \(inner))")
        }

        let ordering: String
        switch query.order {
        case .relevance where pattern != nil:
            ordering = "bm25(issueSearch, 10.0, 5.0, 1.0), issue.updatedAt DESC"
        case .manual, .relevance:
            ordering = "issue.teamId, workflowState.position, issue.sortKey"
        case .priority:
            ordering = "CASE issue.priority WHEN 0 THEN 5 ELSE issue.priority END, issue.updatedAt DESC"
        case .updated:
            ordering = "issue.updatedAt DESC"
        case .created:
            ordering = "issue.createdAt DESC"
        case .due:
            ordering = "issue.dueDate IS NULL, issue.dueDate, CASE issue.priority WHEN 0 THEN 5 ELSE issue.priority END"
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = "SELECT issue.* FROM issue \(joins.joined(separator: " ")) \(whereClause) ORDER BY \(ordering), issue.seq LIMIT ? OFFSET ?"
        arguments.append(limit + 1)
        arguments.append(offset)

        let rows = try writer.read { db in
            try Issue.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
        let hasMore = rows.count > limit
        return IssuePage(issues: Array(rows.prefix(limit)), nextOffset: hasMore ? offset + limit : nil)
    }

    /// Label ids per issue, for presenting a page of issues with one query.
    public func labelIds(forIssues issueIds: [String]) throws -> [String: [String]] {
        guard !issueIds.isEmpty else { return [:] }
        return try writer.read { db in
            var arguments: [any DatabaseValueConvertible] = []
            let condition = Self.membership("issueId", issueIds, &arguments)
            let rows = try Row.fetchAll(db, sql: "SELECT issueId, labelId FROM issueLabel WHERE \(condition)", arguments: StatementArguments(arguments))
            var result: [String: [String]] = [:]
            for row in rows {
                let issueId: String = row["issueId"]
                let labelId: String = row["labelId"]
                result[issueId, default: []].append(labelId)
            }
            return result
        }
    }

    /// The cycle running now for a team: started, not yet ended, not completed.
    public func activeCycle(teamId: String) throws -> Cycle? {
        let now = clock()
        return try writer.read { db in
            try Cycle
                .filter(Column("teamId") == teamId && Column("startsAt") <= now && Column("endsAt") > now && Column("completedAt") == nil)
                .order(Column("number").desc)
                .fetchOne(db)
        }
    }

    public func cycleProgress(cycleId: String) throws -> CycleProgress {
        try writer.read { db in
            guard let cycle = try Cycle.fetchOne(db, key: cycleId) else {
                throw TrackaroError.notFound(entity: "cycle", reference: cycleId)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT workflowState.category AS category, COUNT(*) AS count, COALESCE(SUM(issue.estimate), 0) AS points
                FROM issue JOIN workflowState ON workflowState.id = issue.stateId
                WHERE issue.cycleId = ? AND issue.archivedAt IS NULL
                GROUP BY workflowState.category
                """, arguments: [cycleId])
            var counts: [StateCategory: Int] = [:]
            var total = 0
            var completedPoints = 0
            var totalPoints = 0
            for row in rows {
                guard let category = StateCategory(rawValue: row["category"]) else { continue }
                let count: Int = row["count"]
                let points: Int = row["points"]
                counts[category] = count
                total += count
                if category != .canceled { totalPoints += points }
                if category == .completed { completedPoints += points }
            }
            return CycleProgress(cycle: cycle, issueCount: total, countByCategory: counts, totalEstimate: totalPoints, completedEstimate: completedPoints)
        }
    }

    /// An FTS5 prefix query from free text, or nil when the text has no searchable words.
    static func ftsPattern(_ text: String) -> String? {
        let words = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private static func membership<Value: DatabaseValueConvertible>(
        _ column: String, _ values: [Value], _ arguments: inout [any DatabaseValueConvertible]
    ) -> String {
        guard !values.isEmpty else { return "0" }
        arguments.append(contentsOf: values.map { $0 as any DatabaseValueConvertible })
        return "\(column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))"
    }

    private static func reference(_ column: String, _ filter: ReferenceFilter, _ arguments: inout [any DatabaseValueConvertible]) -> String {
        switch filter {
        case .none: "\(column) IS NULL"
        case let .anyOf(ids): membership(column, ids, &arguments)
        case let .noneOrAnyOf(ids): "(\(column) IS NULL OR \(membership(column, ids, &arguments)))"
        }
    }
}
