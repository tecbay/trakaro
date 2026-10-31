import Foundation
import GRDB

/// Every small reference table, read in one transaction. Callers that present issues use it to turn ids into
/// names without a query per row. These tables stay small (tens to hundreds of rows), so loading them whole is cheap.
public struct WorkspaceSnapshot: Sendable {
    public let teams: [Team]
    public let states: [WorkflowState]
    public let labels: [IssueLabel]
    public let members: [Member]
    public let projects: [Project]
    public let milestones: [Milestone]
    public let cycles: [Cycle]
    public let savedViews: [SavedView]

    public let teamsById: [String: Team]
    public let statesById: [String: WorkflowState]
    public let labelsById: [String: IssueLabel]
    public let membersById: [String: Member]
    public let projectsById: [String: Project]
    public let milestonesById: [String: Milestone]
    public let cyclesById: [String: Cycle]
    public let savedViewsById: [String: SavedView]

    init(teams: [Team], states: [WorkflowState], labels: [IssueLabel], members: [Member], projects: [Project], milestones: [Milestone], cycles: [Cycle], savedViews: [SavedView]) {
        self.teams = teams
        self.states = states
        self.labels = labels
        self.members = members
        self.projects = projects
        self.milestones = milestones
        self.cycles = cycles
        self.savedViews = savedViews
        teamsById = Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0) })
        statesById = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        labelsById = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
        membersById = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        projectsById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        milestonesById = Dictionary(uniqueKeysWithValues: milestones.map { ($0.id, $0) })
        cyclesById = Dictionary(uniqueKeysWithValues: cycles.map { ($0.id, $0) })
        savedViewsById = Dictionary(uniqueKeysWithValues: savedViews.map { ($0.id, $0) })
    }

    public func states(ofTeam teamId: String) -> [WorkflowState] {
        states.filter { $0.teamId == teamId }
    }
}

extension TrackaroStore {
    public func snapshot() throws -> WorkspaceSnapshot {
        try writer.read { db in
            WorkspaceSnapshot(
                teams: try Team.order(Column("createdAt")).fetchAll(db),
                states: try WorkflowState.order(Column("teamId"), Column("position")).fetchAll(db),
                labels: try IssueLabel.order(Column("name").collating(.nocase)).fetchAll(db),
                members: try Member.order(Column("createdAt")).fetchAll(db),
                projects: try Project.order(Column("sortKey")).fetchAll(db),
                milestones: try Milestone.order(Column("projectId"), Column("sortKey")).fetchAll(db),
                cycles: try Cycle.order(Column("teamId"), Column("number")).fetchAll(db),
                savedViews: try SavedView.order(Column("sortKey")).fetchAll(db)
            )
        }
    }

    /// Identifiers for a set of issue ids, for showing parents and relations without loading whole issues.
    public func identifiers(forIssueIds ids: [String]) throws -> [String: String] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        return try writer.read { db in
            let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT id, identifier FROM issue WHERE id IN (\(placeholders))", arguments: StatementArguments(unique))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String, $0["identifier"] as String) })
        }
    }

    public func commentCount(issueId: String) throws -> Int {
        try writer.read { db in
            try Comment.filter(Column("issueId") == issueId && Column("deletedAt") == nil).fetchCount(db)
        }
    }

    public func now() -> Date { clock() }

    /// Issues most recently changed by members of one kind, newest first, with who changed each and when.
    /// With `.agent` this is the "what did my agents do" feed.
    public func recentChanges(by kind: MemberKind, limit: Int = 200) throws -> [RecentChange] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT changeLog.modelId AS issueId, changeLog.memberId AS memberId, changeLog.at AS at, MAX(changeLog.seq) AS seq
                FROM changeLog JOIN member ON member.id = changeLog.memberId
                WHERE changeLog.model = 'issue' AND member.kind = ?
                GROUP BY changeLog.modelId
                ORDER BY seq DESC
                LIMIT ?
                """, arguments: [kind.rawValue, limit])
            let issueIds: [String] = rows.map { $0["issueId"] }
            guard !issueIds.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: issueIds.count).joined(separator: ",")
            let issues = try Issue.fetchAll(db, sql: "SELECT * FROM issue WHERE id IN (\(placeholders)) AND archivedAt IS NULL", arguments: StatementArguments(issueIds))
            let issuesById = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
            let members = Dictionary(uniqueKeysWithValues: try Member.fetchAll(db).map { ($0.id, $0) })
            return rows.compactMap { row in
                guard let issue = issuesById[row["issueId"]], let member = members[row["memberId"]] else { return nil }
                return RecentChange(issue: issue, member: member, at: row["at"])
            }
        }
    }
}

public struct RecentChange: Sendable, Equatable {
    public let issue: Issue
    public let member: Member
    public let at: Date
}
