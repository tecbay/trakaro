import Foundation
import Testing
@testable import TrackaroCore
@testable import TrackaroKit

@Suite("List rows")
struct IssueRowTests {
    @Test func groupsByStateInWorkflowOrderWithCounts() throws {
        let fixture = try KitFixture()
        let store = fixture.store
        for (title, state) in [("A", "Done"), ("B", "Todo"), ("C", "Todo"), ("D", "In Progress")] {
            _ = try store.createIssue(NewIssue(teamId: fixture.team.id, title: title, stateId: try fixture.state(state).id), by: fixture.me.id)
        }
        let issues = try store.issues(teamId: fixture.team.id)
        let rows = IssueRowBuilder.rows(issues, snapshot: try store.snapshot(), labelIds: [:], parentIdentifiers: [:], grouping: .state)
        let headers = rows.compactMap { row -> String? in
            if case let .group(header) = row { "\(header.title) \(header.count)" } else { nil }
        }
        #expect(headers == ["Todo 2", "In Progress 1", "Done 1"])
        #expect(rows.count == 7)
        #expect(rows.compactMap(\.issueId).count == 4)
    }

    @Test func categoryGroupingSpansTeams() throws {
        let fixture = try KitFixture()
        let store = fixture.store
        let ops = try store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        let opsTodo = try #require(try store.states(teamId: ops.id).first { $0.category == .unstarted })
        _ = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Eng", stateId: try fixture.state("Todo").id), by: fixture.me.id)
        _ = try store.createIssue(NewIssue(teamId: ops.id, title: "Ops", stateId: opsTodo.id), by: fixture.me.id)
        let issues = try store.queryIssues(IssueQuery()).issues
        let rows = IssueRowBuilder.rows(issues, snapshot: try store.snapshot(), labelIds: [:], parentIdentifiers: [:], grouping: .category)
        guard case let .group(header) = rows.first else { throw TrackaroError.invalid(field: "rows", message: "no header") }
        #expect(header.title == "Todo")
        #expect(header.count == 2)
    }

    @Test func itemsResolveNamesLabelsAndAgents() throws {
        let fixture = try KitFixture()
        let store = fixture.store
        let claude = try store.agent(named: "Claude Code")
        let ui = try store.createLabel(name: "ui", color: "#0f0", teamId: nil, by: fixture.me.id)
        let bug = try store.createLabel(name: "Bug", color: "#f00", teamId: nil, by: fixture.me.id)
        let parent = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Parent"), by: fixture.me.id)
        let child = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Child", priority: .high, assigneeId: claude.id, parentId: parent.id, labelIds: [ui.id, bug.id]), by: fixture.me.id)
        let item = IssueRowBuilder.item(child, snapshot: try store.snapshot(), labelIds: [ui.id, bug.id], parentIdentifier: parent.identifier, note: "note")
        #expect(item.labels.map(\.name) == ["Bug", "ui"])
        #expect(item.assignee == "Claude Code")
        #expect(item.assigneeIsAgent)
        #expect(item.parentIdentifier == "ENG-1")
        #expect(item.stateName == "Backlog")
        #expect(item.note == "note")
    }
}
