import Foundation
import TrackaroCore

/// One issue's change, as the values before and after for exactly the fields that changed.
public struct IssueEdit: Sendable, Equatable {
    public let issueId: String
    public let before: IssuePatch
    public let after: IssuePatch
    public let labelsBefore: [String]?
    public let labelsAfter: [String]?

    public init(issueId: String, before: IssuePatch, after: IssuePatch, labelsBefore: [String]? = nil, labelsAfter: [String]? = nil) {
        self.issueId = issueId
        self.before = before
        self.after = after
        self.labelsBefore = labelsBefore
        self.labelsAfter = labelsAfter
    }

    /// Captures what a store update did, including side effects such as a milestone cleared by a project change.
    public init(original: Issue, updated: Issue, changed: [IssueField]) {
        self.init(
            issueId: original.id,
            before: Self.values(of: original, fields: changed),
            after: Self.values(of: updated, fields: changed)
        )
    }

    public static func labels(issueId: String, before: [String], after: [String]) -> IssueEdit {
        IssueEdit(issueId: issueId, before: IssuePatch(), after: IssuePatch(), labelsBefore: before.sorted(), labelsAfter: after.sorted())
    }

    static func values(of issue: Issue, fields: [IssueField]) -> IssuePatch {
        var patch = IssuePatch()
        for field in fields {
            switch field {
            case .title: patch.title = issue.title
            case .description: patch.description = issue.description
            case .state: patch.stateId = issue.stateId
            case .priority: patch.priority = issue.priority
            case .estimate: patch.estimate = update(issue.estimate)
            case .dueDate: patch.dueDate = update(issue.dueDate)
            case .assignee: patch.assigneeId = update(issue.assigneeId)
            case .parent: patch.parentId = update(issue.parentId)
            case .project: patch.projectId = update(issue.projectId)
            case .milestone: patch.milestoneId = update(issue.milestoneId)
            case .cycle: patch.cycleId = update(issue.cycleId)
            case .created, .labels, .team, .position, .archived, .relation: break
            }
        }
        return patch
    }

    private static func update<Value>(_ value: Value?) -> FieldUpdate<Value> {
        value.map(FieldUpdate.set) ?? .clear
    }
}

/// A user action that may span several issues, undone and redone as one step.
public struct EditBatch: Sendable, Equatable {
    public let label: String
    public let edits: [IssueEdit]

    public init(label: String, edits: [IssueEdit]) {
        self.label = label
        self.edits = edits
    }
}

/// Undo and redo for issue edits.
///
/// Undo writes the "before" values only if the issue still holds the "after" values, using the store's
/// compare-and-set. If an agent or another window changed the field since, undo refuses with a conflict instead
/// of overwriting newer work, and that step is dropped from the history.
public struct EditHistory: Sendable {
    public static let limit = 50

    public private(set) var undoStack: [EditBatch] = []
    public private(set) var redoStack: [EditBatch] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ batch: EditBatch) {
        let meaningful = batch.edits.filter { $0.before != $0.after || $0.labelsBefore != $0.labelsAfter }
        guard !meaningful.isEmpty else { return }
        undoStack.append(EditBatch(label: batch.label, edits: meaningful))
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        redoStack.removeAll()
    }

    @discardableResult
    public mutating func undo(in store: TrackaroStore, by memberId: String) throws -> EditBatch? {
        guard let batch = undoStack.popLast() else { return nil }
        try Self.apply(batch, reversed: true, store: store, memberId: memberId)
        redoStack.append(batch)
        return batch
    }

    @discardableResult
    public mutating func redo(in store: TrackaroStore, by memberId: String) throws -> EditBatch? {
        guard let batch = redoStack.popLast() else { return nil }
        try Self.apply(batch, reversed: false, store: store, memberId: memberId)
        undoStack.append(batch)
        return batch
    }

    private static func apply(_ batch: EditBatch, reversed: Bool, store: TrackaroStore, memberId: String) throws {
        let edits = reversed ? batch.edits.reversed() : batch.edits
        for edit in edits {
            let target = reversed ? edit.before : edit.after
            let expected = reversed ? edit.after : edit.before
            if target != IssuePatch() {
                _ = try store.updateIssue(edit.issueId, target, expecting: expected, by: memberId)
            }
            if let wanted = reversed ? edit.labelsBefore : edit.labelsAfter,
               let required = reversed ? edit.labelsAfter : edit.labelsBefore {
                let current = try store.labels(forIssue: edit.issueId).map(\.id).sorted()
                guard current == required else {
                    let identifier = (try? store.issue(edit.issueId).identifier) ?? edit.issueId
                    throw TrackaroError.conflict(message: "\(identifier) changed since it was read: labels.", candidates: [])
                }
                _ = try store.setLabels(wanted, on: edit.issueId, by: memberId)
            }
        }
    }
}
