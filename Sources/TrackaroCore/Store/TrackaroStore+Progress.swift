import Foundation
import GRDB

/// How far along a set of issues is: counts per state category and estimate points.
public struct IssueProgress: Sendable, Equatable {
    public private(set) var countByCategory: [StateCategory: Int] = [:]
    public private(set) var totalEstimate = 0
    public private(set) var completedEstimate = 0

    public init() {}

    public var issueCount: Int { countByCategory.values.reduce(0, +) }
    public var completedCount: Int { countByCategory[.completed] ?? 0 }
    public var canceledCount: Int { countByCategory[.canceled] ?? 0 }
    public var startedCount: Int { (countByCategory[.started] ?? 0) + (countByCategory[.review] ?? 0) }
    /// Issues still to finish. Canceled issues are out of scope, not open.
    public var openCount: Int { issueCount - completedCount - canceledCount }

    /// Completed share of the issues in scope (canceled ones excluded), from 0 to 1. Zero when nothing is in scope.
    public var fraction: Double {
        let scope = issueCount - canceledCount
        return scope > 0 ? Double(completedCount) / Double(scope) : 0
    }

    mutating func add(_ category: StateCategory, count: Int, points: Int) {
        countByCategory[category, default: 0] += count
        if category != .canceled { totalEstimate += points }
        if category == .completed { completedEstimate += points }
    }
}

public struct MilestoneProgress: Sendable, Equatable, Identifiable {
    public let milestone: Milestone
    public let progress: IssueProgress

    public var id: String { milestone.id }
}

public struct ProjectProgress: Sendable, Equatable {
    public let project: Project
    public let overall: IssueProgress
    /// Every milestone in order, including ones with no issues yet.
    public let milestones: [MilestoneProgress]
}

/// What a project update may change. Nil keeps a field; `.clear` empties an optional one.
public struct ProjectPatch: Sendable, Equatable {
    public var name: String?
    public var summary: String?
    public var status: ProjectStatus?
    public var health: ProjectHealth?
    public var leadId: FieldUpdate<String>?
    public var startDate: FieldUpdate<CalendarDate>?
    public var targetDate: FieldUpdate<CalendarDate>?

    public init(
        name: String? = nil, summary: String? = nil, status: ProjectStatus? = nil, health: ProjectHealth? = nil,
        leadId: FieldUpdate<String>? = nil, startDate: FieldUpdate<CalendarDate>? = nil, targetDate: FieldUpdate<CalendarDate>? = nil
    ) {
        self.name = name
        self.summary = summary
        self.status = status
        self.health = health
        self.leadId = leadId
        self.startDate = startDate
        self.targetDate = targetDate
    }
}

extension TrackaroStore {
    public func projectProgress(projectId: String) throws -> ProjectProgress {
        try writer.read { db in
            guard let project = try Project.fetchOne(db, key: projectId) else {
                throw TrackaroError.notFound(entity: "project", reference: projectId)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT issue.milestoneId AS milestoneId, workflowState.category AS category,
                       COUNT(*) AS count, COALESCE(SUM(issue.estimate), 0) AS points
                FROM issue JOIN workflowState ON workflowState.id = issue.stateId
                WHERE issue.projectId = ? AND issue.archivedAt IS NULL
                GROUP BY issue.milestoneId, workflowState.category
                """, arguments: [projectId])
            var overall = IssueProgress()
            var byMilestone: [String: IssueProgress] = [:]
            for row in rows {
                guard let category = StateCategory(rawValue: row["category"]) else { continue }
                let count: Int = row["count"]
                let points: Int = row["points"]
                overall.add(category, count: count, points: points)
                if let milestoneId: String = row["milestoneId"] {
                    byMilestone[milestoneId, default: IssueProgress()].add(category, count: count, points: points)
                }
            }
            let milestones = try Milestone.filter(Column("projectId") == projectId).order(Column("sortKey")).fetchAll(db)
            return ProjectProgress(
                project: project, overall: overall,
                milestones: milestones.map { MilestoneProgress(milestone: $0, progress: byMilestone[$0.id] ?? IssueProgress()) }
            )
        }
    }

    /// Progress of every project in one query, for the projects overview.
    public func projectsProgress() throws -> [String: IssueProgress] {
        try grouped(by: "issue.projectId", where: "issue.projectId IS NOT NULL", arguments: [])
    }

    /// Progress of every cycle of a team in one query, for the cycles overview.
    public func cyclesProgress(teamId: String) throws -> [String: IssueProgress] {
        try grouped(by: "issue.cycleId", where: "issue.cycleId IS NOT NULL AND issue.teamId = ?", arguments: [teamId])
    }

    @discardableResult
    public func updateProject(_ id: String, _ patch: ProjectPatch, by memberId: String) throws -> Project {
        let name = patch.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, name.isEmpty { throw TrackaroError.invalid(field: "name", message: "A project needs a name.") }
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            guard var project = try Project.fetchOne(db, key: id) else { throw TrackaroError.notFound(entity: "project", reference: id) }
            if let name { project.name = name }
            if let summary = patch.summary { project.summary = summary }
            if let status = patch.status { project.status = status }
            if let health = patch.health { project.health = health }
            if let lead = patch.leadId {
                if let leadId = lead.value { _ = try requireMember(db, leadId) }
                project.leadId = lead.value
            }
            if let start = patch.startDate { project.startDate = start.value }
            if let target = patch.targetDate { project.targetDate = target.value }
            if let start = project.startDate, let target = project.targetDate, target < start {
                throw TrackaroError.invalid(field: "targetDate", message: "The target date is before the start date.")
            }
            project.updatedAt = now
            try project.update(db)
            try recordChange(db, model: "project", id: project.id, action: .update, by: memberId, at: now, snapshot: project)
            return project
        }
    }

    /// Closes a cycle. Its unfinished issues stay where they are; the app offers to move them to the next cycle.
    @discardableResult
    public func completeCycle(_ id: String, by memberId: String) throws -> Cycle {
        try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            guard var cycle = try Cycle.fetchOne(db, key: id) else { throw TrackaroError.notFound(entity: "cycle", reference: id) }
            guard cycle.completedAt == nil else {
                throw TrackaroError.invalid(field: "cycle", message: "Cycle \(cycle.number) is already complete.")
            }
            cycle.completedAt = now
            cycle.updatedAt = now
            try cycle.update(db)
            try recordChange(db, model: "cycle", id: cycle.id, action: .update, by: memberId, at: now, snapshot: cycle)
            return cycle
        }
    }

    /// The cycle after this one in its team, if there is one.
    public func nextCycle(after cycle: Cycle) throws -> Cycle? {
        try writer.read { db in
            try Cycle.filter(Column("teamId") == cycle.teamId && Column("number") > cycle.number)
                .order(Column("number"))
                .fetchOne(db)
        }
    }

    private func grouped(by column: String, where condition: String, arguments: StatementArguments) throws -> [String: IssueProgress] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(column) AS owner, workflowState.category AS category,
                       COUNT(*) AS count, COALESCE(SUM(issue.estimate), 0) AS points
                FROM issue JOIN workflowState ON workflowState.id = issue.stateId
                WHERE \(condition) AND issue.archivedAt IS NULL
                GROUP BY \(column), workflowState.category
                """, arguments: arguments)
            var result: [String: IssueProgress] = [:]
            for row in rows {
                guard let owner: String = row["owner"], let category = StateCategory(rawValue: row["category"]) else { continue }
                result[owner, default: IssueProgress()].add(category, count: row["count"], points: row["points"])
            }
            return result
        }
    }
}

extension CycleProgress {
    /// The same counts as an `IssueProgress`, for views that draw either.
    public var issueProgress: IssueProgress {
        var progress = IssueProgress()
        for (category, count) in countByCategory {
            progress.add(category, count: count, points: category == .completed ? completedEstimate : 0)
        }
        return progress
    }
}
