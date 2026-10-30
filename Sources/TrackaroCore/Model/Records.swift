import Foundation
import GRDB

/// Who made a change: the local user, a coding agent connected over MCP, or the app itself.
public struct Member: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "member"
    public var id: String
    public var kind: MemberKind
    public var name: String
    /// For agents, the MCP client name reported at connection time, such as "claude-code" or "cursor".
    public var clientName: String?
    public var createdAt: Date
}

public struct Team: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "team"
    public var id: String
    public var key: String
    public var name: String
    /// Last issue number handed out. Only ever increases, so identifiers are never reused.
    public var issueCounter: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
}

public struct WorkflowState: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workflowState"
    public var id: String
    public var teamId: String
    public var name: String
    public var category: StateCategory
    public var color: String
    public var position: Int
}

/// A label definition. Named `IssueLabel` to stay clear of SwiftUI's `Label`.
public struct IssueLabel: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "label"
    public var id: String
    /// Nil means the label is available to every team.
    public var teamId: String?
    public var name: String
    public var color: String
    public var createdAt: Date
}

public struct Project: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"
    public var id: String
    public var name: String
    public var slug: String
    public var summary: String
    public var description: String
    public var status: ProjectStatus
    public var health: ProjectHealth
    public var leadId: String?
    public var startDate: CalendarDate?
    public var targetDate: CalendarDate?
    public var sortKey: String
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
}

public struct Milestone: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "milestone"
    public var id: String
    public var projectId: String
    public var name: String
    public var description: String
    public var targetDate: CalendarDate?
    public var sortKey: String
    public var createdAt: Date
    public var updatedAt: Date
}

public struct Cycle: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "cycle"
    public var id: String
    public var teamId: String
    public var number: Int
    public var name: String?
    public var startsAt: Date
    public var endsAt: Date
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct Issue: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "issue"
    /// SQLite rowid alias. Exists so the full-text index has a stable rowid; use `id` everywhere else.
    public var seq: Int64?
    public var id: String
    public var teamId: String
    public var number: Int
    public var identifier: String
    public var title: String
    public var description: String
    public var stateId: String
    public var priority: Priority
    public var estimate: Int?
    public var dueDate: CalendarDate?
    public var sortKey: String
    public var parentId: String?
    public var projectId: String?
    public var milestoneId: String?
    public var cycleId: String?
    public var assigneeId: String?
    public var creatorId: String
    public var startedAt: Date?
    public var completedAt: Date?
    public var canceledAt: Date?
    public var stateEnteredAt: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    /// Bumped on every write. Lets a reader tell that what it holds is stale.
    public var version: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        seq = inserted.rowID
    }
}

struct IssueAlias: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "issueAlias"
    var identifier: String
    var issueId: String
}

struct IssueLabelLink: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "issueLabel"
    var issueId: String
    var labelId: String
}

public struct IssueRelation: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "issueRelation"
    public var issueId: String
    public var relatedIssueId: String
    public var type: RelationType
    public var createdAt: Date
}

public struct Comment: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "comment"
    public var id: String
    public var issueId: String
    public var authorId: String
    public var parentId: String?
    public var body: String
    public var createdAt: Date
    public var editedAt: Date?
    public var deletedAt: Date?
}

/// One field change on one issue. Values are JSON so history survives schema changes.
public struct IssueActivity: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "issueActivity"
    public var id: String
    public var issueId: String
    public var memberId: String
    public var field: IssueField
    public var fromValue: String?
    public var toValue: String?
    public var createdAt: Date
}

public struct SavedView: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "savedView"
    public var id: String
    public var name: String
    /// JSON filter document. Its grammar is defined by the query layer.
    public var filter: String
    public var layout: ViewLayout
    public var groupBy: String?
    public var sortKey: String
    public var createdAt: Date
    public var updatedAt: Date
}

/// Append-only log of every write. `seq` is the change cursor a future sync engine or another process reads from.
public struct ChangeEntry: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "changeLog"
    public var seq: Int64?
    public var model: String
    public var modelId: String
    public var action: ChangeAction
    public var memberId: String?
    public var at: Date
    /// JSON snapshot of the row after the write, or nil for deletes.
    public var payload: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        seq = inserted.rowID
    }
}
