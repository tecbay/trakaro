import Foundation

/// A change to a field that may be empty. A nil `FieldUpdate?` leaves the field alone; `.clear` empties it.
public enum FieldUpdate<Value: Sendable & Equatable>: Sendable, Equatable {
    case set(Value)
    case clear

    public var value: Value? {
        if case let .set(value) = self { value } else { nil }
    }
}

public struct NewIssue: Sendable, Equatable {
    public var teamId: String
    public var title: String
    public var description: String
    public var stateId: String?
    public var priority: Priority
    public var estimate: Int?
    public var dueDate: CalendarDate?
    public var assigneeId: String?
    public var parentId: String?
    public var projectId: String?
    public var milestoneId: String?
    public var cycleId: String?
    public var labelIds: [String]

    public init(
        teamId: String,
        title: String,
        description: String = "",
        stateId: String? = nil,
        priority: Priority = .none,
        estimate: Int? = nil,
        dueDate: CalendarDate? = nil,
        assigneeId: String? = nil,
        parentId: String? = nil,
        projectId: String? = nil,
        milestoneId: String? = nil,
        cycleId: String? = nil,
        labelIds: [String] = []
    ) {
        self.teamId = teamId
        self.title = title
        self.description = description
        self.stateId = stateId
        self.priority = priority
        self.estimate = estimate
        self.dueDate = dueDate
        self.assigneeId = assigneeId
        self.parentId = parentId
        self.projectId = projectId
        self.milestoneId = milestoneId
        self.cycleId = cycleId
        self.labelIds = labelIds
    }
}

/// A partial update. Only non-nil properties are applied.
///
/// The same type doubles as an expectation for compare-and-set: pass the values you last read as `expecting`
/// and the update is refused if any of them changed underneath you. Undo uses this so it never clobbers a newer edit.
public struct IssuePatch: Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var stateId: String?
    public var priority: Priority?
    public var estimate: FieldUpdate<Int>?
    public var dueDate: FieldUpdate<CalendarDate>?
    public var assigneeId: FieldUpdate<String>?
    public var parentId: FieldUpdate<String>?
    public var projectId: FieldUpdate<String>?
    public var milestoneId: FieldUpdate<String>?
    public var cycleId: FieldUpdate<String>?

    public init(
        title: String? = nil,
        description: String? = nil,
        stateId: String? = nil,
        priority: Priority? = nil,
        estimate: FieldUpdate<Int>? = nil,
        dueDate: FieldUpdate<CalendarDate>? = nil,
        assigneeId: FieldUpdate<String>? = nil,
        parentId: FieldUpdate<String>? = nil,
        projectId: FieldUpdate<String>? = nil,
        milestoneId: FieldUpdate<String>? = nil,
        cycleId: FieldUpdate<String>? = nil
    ) {
        self.title = title
        self.description = description
        self.stateId = stateId
        self.priority = priority
        self.estimate = estimate
        self.dueDate = dueDate
        self.assigneeId = assigneeId
        self.parentId = parentId
        self.projectId = projectId
        self.milestoneId = milestoneId
        self.cycleId = cycleId
    }
}

/// Moves an issue to another state, team or position. Neighbours accept an id or an identifier.
public struct IssueMove: Sendable, Equatable {
    public var teamId: String?
    public var stateId: String?
    /// Place the issue directly below this one.
    public var afterIssue: String?
    /// Place the issue directly above this one.
    public var beforeIssue: String?

    public init(teamId: String? = nil, stateId: String? = nil, afterIssue: String? = nil, beforeIssue: String? = nil) {
        self.teamId = teamId
        self.stateId = stateId
        self.afterIssue = afterIssue
        self.beforeIssue = beforeIssue
    }
}

public struct IssueChange: Sendable, Equatable {
    public let issue: Issue
    /// Fields whose stored value changed. Empty means the call was a no-op.
    public let changed: [IssueField]
}

struct FieldDelta {
    let field: IssueField
    let from: String?
    let to: String?
}
