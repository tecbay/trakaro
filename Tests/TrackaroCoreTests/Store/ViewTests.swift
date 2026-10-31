import Foundation
import Testing
@testable import TrackaroCore

@Suite("Filters and saved views")
struct ViewTests {
    @Test func filterNarrowsAndNeverWidensTheBaseQuery() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let mine = try fixture.issue("Mine urgent", state: "In Progress")
        let other = try fixture.issue("Unassigned urgent", state: "In Progress")
        try fixture.issue("Mine low", state: "Todo")
        _ = try store.updateIssue(mine.id, IssuePatch(priority: .urgent, assigneeId: .set(fixture.me.id)), by: fixture.me.id)
        _ = try store.updateIssue(other.id, IssuePatch(priority: .urgent), by: fixture.me.id)
        _ = try store.updateIssue(try store.issue("ENG-3").id, IssuePatch(priority: .low, assigneeId: .set(fixture.me.id)), by: fixture.me.id)

        let myIssues = IssueQuery(assignee: .anyOf([fixture.me.id]))
        let urgent = IssueFilter(priorities: [.urgent])
        #expect(try store.queryIssues(urgent.applied(to: myIssues)).issues.map(\.identifier) == ["ENG-1"])
        #expect(Set(try store.queryIssues(urgent.applied(to: IssueQuery())).issues.map(\.identifier)) == ["ENG-1", "ENG-2"])

        let unassigned = IssueFilter(assigneeIds: [IssueFilter.unset])
        #expect(try store.queryIssues(unassigned.applied(to: IssueQuery())).issues.map(\.identifier) == ["ENG-2"])
        #expect(try store.queryIssues(unassigned.applied(to: myIssues)).issues.isEmpty)

        let eitherWay = IssueFilter(stateCategories: [.started], assigneeIds: [IssueFilter.unset, fixture.me.id])
        #expect(Set(try store.queryIssues(eitherWay.applied(to: IssueQuery())).issues.map(\.identifier)) == ["ENG-1", "ENG-2"])
    }

    @Test func textAndLabelsCombineWithTheBase() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let bug = try store.createLabel(name: "bug", color: "#f00", teamId: nil, by: fixture.me.id)
        let login = try fixture.issue("Login button broken")
        try fixture.issue("Login copy tweak")
        _ = try store.addLabels([bug.id], to: login.id, by: fixture.me.id)

        let filter = IssueFilter(text: "  login ", labelIds: [bug.id])
        #expect(try store.queryIssues(filter.applied(to: IssueQuery(text: "button"))).issues.map(\.identifier) == ["ENG-1"])
        #expect(try store.queryIssues(IssueQuery(issueIds: [login.id])).issues.count == 1)
    }

    @Test func narrowingMatchesApplyingBoth() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let started = try fixture.issue("Login started", state: "In Progress")
        try fixture.issue("Login todo", state: "Todo")
        _ = try store.updateIssue(started.id, IssuePatch(assigneeId: .set(fixture.me.id)), by: fixture.me.id)

        let page = IssueFilter(stateCategories: [.unstarted, .started], assigneeIds: [fixture.me.id, IssueFilter.unset])
        let filter = IssueFilter(text: "login", stateCategories: [.started, .completed])
        let combined = page.narrowed(by: filter)
        #expect(combined == IssueFilter(text: "login", stateCategories: [.started], assigneeIds: [fixture.me.id, IssueFilter.unset]))
        let both = filter.applied(to: page.applied(to: IssueQuery()))
        #expect(try store.queryIssues(combined.applied(to: IssueQuery())) == store.queryIssues(both))
        #expect(IssueFilter().narrowed(by: IssueFilter()).isEmpty)
    }

    @Test func normalizingDropsEmptyDimensions() throws {
        var filter = IssueFilter(text: "  ", priorities: [])
        #expect(filter.isEmpty)
        filter.priorities = IssueFilter.toggling(Priority.high, in: filter.priorities)
        #expect(filter.priorities == [.high])
        #expect(filter.count == 1)
        filter.priorities = IssueFilter.toggling(Priority.high, in: filter.priorities)
        #expect(filter.priorities == nil)

        let stored = IssueFilter(stateCategories: [.started], priorities: [.urgent, .high], assigneeIds: ["none"])
        #expect(try IssueFilter(json: stored.json) == stored)
        #expect(stored.json == #"{"assigneeIds":["none"],"priorities":[1,2],"stateCategories":["started"]}"#)
        #expect(throws: TrackaroError.self) { try IssueFilter(json: "{\"priorities\":\"high\"}") }
    }

    @Test func viewsAreNamedUniquelyAndRecordChanges() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let before = try store.latestChangeSeq()
        let urgent = try store.createView(name: " Urgent ", filter: IssueFilter(priorities: [.urgent]), layout: .board, by: fixture.me.id)
        let mine = try store.createView(name: "Mine", filter: IssueFilter(assigneeIds: [fixture.me.id]), by: fixture.me.id)
        #expect(urgent.name == "Urgent")
        #expect(try store.views().map(\.name) == ["Urgent", "Mine"])
        #expect(try store.snapshot().savedViews.map(\.id) == [urgent.id, mine.id])
        #expect(try store.view("urgent").id == urgent.id)
        #expect(try store.latestChangeSeq() == before + 2)

        #expect(throws: TrackaroError.self) { try store.createView(name: "MINE", filter: IssueFilter(), by: fixture.me.id) }
        #expect(throws: TrackaroError.self) { try store.createView(name: "  ", filter: IssueFilter(), by: fixture.me.id) }

        let renamed = try store.updateView("Mine", name: "Assigned to me", filter: IssueFilter(priorities: [.high]), by: fixture.me.id)
        #expect(renamed.issueFilter == IssueFilter(priorities: [.high]))
        #expect(renamed.layout == .list)
        #expect(throws: TrackaroError.self) { try store.updateView(renamed.id, name: "urgent", by: fixture.me.id) }

        try store.deleteView("Urgent", by: fixture.me.id)
        #expect(try store.views().map(\.name) == ["Assigned to me"])
        do {
            _ = try store.view("Urgent")
            Issue.record("expected no match")
        } catch let TrackaroError.noMatch(_, _, options) {
            #expect(options == ["Assigned to me"])
        }
    }
}
