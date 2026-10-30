import Foundation
import Testing
@testable import TrackaroCore
@testable import TrackaroKit

struct KitFixture {
    let store: TrackaroStore
    let me: Member
    let team: Team

    init() throws {
        store = try TrackaroStore.inMemory()
        me = try store.localUser()
        team = try store.createTeam(key: "ENG", name: "Engineering", by: me.id)
    }

    func state(_ name: String) throws -> WorkflowState {
        try #require(try store.states(teamId: team.id).first { $0.name == name })
    }

    /// Applies a patch the way the app does: update, then capture the edit for undo.
    func edit(_ issue: TrackaroCore.Issue, _ patch: IssuePatch, history: inout EditHistory) throws -> TrackaroCore.Issue {
        let change = try store.updateIssue(issue.id, patch, by: me.id)
        history.record(EditBatch(label: "Edit", edits: [IssueEdit(original: issue, updated: change.issue, changed: change.changed)]))
        return change.issue
    }
}

@Suite("Undo and redo")
struct EditHistoryTests {
    @Test func undoAndRedoRestoreFieldValues() throws {
        let fixture = try KitFixture()
        var history = EditHistory()
        let issue = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Original"), by: fixture.me.id)
        _ = try fixture.edit(issue, IssuePatch(title: "Renamed", priority: .high, assigneeId: .set(fixture.me.id)), history: &history)

        let undone = try history.undo(in: fixture.store, by: fixture.me.id)
        #expect(undone?.label == "Edit")
        var current = try fixture.store.issue(issue.id)
        #expect(current.title == "Original")
        #expect(current.priority == Priority.none)
        #expect(current.assigneeId == nil)
        #expect(history.canRedo)

        try history.redo(in: fixture.store, by: fixture.me.id)
        current = try fixture.store.issue(issue.id)
        #expect(current.title == "Renamed")
        #expect(current.assigneeId == fixture.me.id)
        #expect(history.canUndo && !history.canRedo)
    }

    @Test func undoRefusesToClobberAnAgentsNewerEdit() throws {
        let fixture = try KitFixture()
        var history = EditHistory()
        let claude = try fixture.store.agent(named: "Claude Code")
        let issue = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Shared"), by: fixture.me.id)
        _ = try fixture.edit(issue, IssuePatch(stateId: try fixture.state("Todo").id), history: &history)
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(stateId: try fixture.state("In Progress").id), by: claude.id)

        #expect(throws: TrackaroError.self) { try history.undo(in: fixture.store, by: fixture.me.id) }
        #expect(try fixture.store.issue(issue.id).stateId == (try fixture.state("In Progress").id))
        #expect(!history.canUndo)
    }

    @Test func sideEffectsAreUndoneToo() throws {
        let fixture = try KitFixture()
        var history = EditHistory()
        let launch = try fixture.store.createProject(name: "Launch", by: fixture.me.id)
        let other = try fixture.store.createProject(name: "Other", by: fixture.me.id)
        let beta = try fixture.store.createMilestone(projectId: launch.id, name: "Beta", by: fixture.me.id)
        var issue = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Scoped", milestoneId: beta.id), by: fixture.me.id)
        issue = try fixture.edit(issue, IssuePatch(projectId: .set(other.id)), history: &history)
        #expect(issue.milestoneId == nil)
        try history.undo(in: fixture.store, by: fixture.me.id)
        let restored = try fixture.store.issue(issue.id)
        #expect(restored.projectId == launch.id)
        #expect(restored.milestoneId == beta.id)
    }

    @Test func batchesUndoAsOneStepAndLabelsRoundTrip() throws {
        let fixture = try KitFixture()
        var history = EditHistory()
        let bug = try fixture.store.createLabel(name: "bug", color: "#f00", teamId: nil, by: fixture.me.id)
        let first = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "One"), by: fixture.me.id)
        let second = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Two"), by: fixture.me.id)
        var edits: [IssueEdit] = []
        for issue in [first, second] {
            _ = try fixture.store.addLabels([bug.id], to: issue.id, by: fixture.me.id)
            edits.append(.labels(issueId: issue.id, before: [], after: [bug.id]))
        }
        history.record(EditBatch(label: "Add label", edits: edits))
        try history.undo(in: fixture.store, by: fixture.me.id)
        #expect(try fixture.store.labels(forIssue: first.id).isEmpty)
        #expect(try fixture.store.labels(forIssue: second.id).isEmpty)
        try history.redo(in: fixture.store, by: fixture.me.id)
        #expect(try fixture.store.labels(forIssue: second.id).map(\.name) == ["bug"])
    }

    @Test func noOpsAreNotRecordedAndHistoryIsCapped() throws {
        var history = EditHistory()
        history.record(EditBatch(label: "Nothing", edits: [IssueEdit(issueId: "x", before: IssuePatch(), after: IssuePatch())]))
        #expect(!history.canUndo)
        for index in 0..<(EditHistory.limit + 5) {
            history.record(EditBatch(label: "\(index)", edits: [IssueEdit(issueId: "x", before: IssuePatch(title: "a"), after: IssuePatch(title: "b"))]))
        }
        #expect(history.undoStack.count == EditHistory.limit)
        #expect(history.undoStack.first?.label == "5")
    }
}

@Suite("Activity text")
struct ActivityFormatterTests {
    @Test func describesChangesByName() throws {
        let fixture = try KitFixture()
        let store = fixture.store
        let claude = try store.agent(named: "Claude Code")
        let bug = try store.createLabel(name: "bug", color: "#f00", teamId: nil, by: fixture.me.id)
        let issue = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Formatted"), by: fixture.me.id)
        _ = try store.updateIssue(issue.id, IssuePatch(stateId: try fixture.state("In Progress").id, priority: .urgent, assigneeId: .set(claude.id)), by: claude.id)
        _ = try store.addLabels([bug.id], to: issue.id, by: claude.id)
        _ = try store.updateIssue(issue.id, IssuePatch(priority: Priority.none, assigneeId: .clear), by: fixture.me.id)

        let formatter = ActivityFormatter(snapshot: try store.snapshot())
        let lines = try store.activity(issueId: issue.id).map(formatter.describe)
        #expect(lines == [
            "created the issue",
            "moved it from Backlog to In Progress",
            "set priority to Urgent",
            "assigned Claude Code",
            "added label bug",
            "removed the priority",
            "unassigned Claude Code",
        ])
    }
}
