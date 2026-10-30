import Foundation
import Testing
@testable import TrackaroCore

@Suite("Issue queries")
struct QueryTests {
    @Test func filtersByCategoryAssigneeAndLabel() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let bug = try store.createLabel(name: "bug", color: "#f00", teamId: nil, by: fixture.me.id)
        let started = try fixture.issue("Started", state: "In Progress")
        let done = try fixture.issue("Done", state: "Done")
        try fixture.issue("Backlog")
        _ = try store.updateIssue(started.id, IssuePatch(assigneeId: .set(fixture.me.id)), by: fixture.me.id)
        _ = try store.addLabels([bug.id], to: done.id, by: fixture.me.id)

        let open = try store.queryIssues(IssueQuery(stateCategories: StateCategory.allCases.filter(\.isOpen)))
        #expect(Set(open.issues.map(\.identifier)) == ["ENG-1", "ENG-3"])
        #expect(try store.queryIssues(IssueQuery(assignee: .anyOf([fixture.me.id]))).issues.map(\.identifier) == ["ENG-1"])
        #expect(try store.queryIssues(IssueQuery(assignee: ReferenceFilter.none)).issues.count == 2)
        #expect(try store.queryIssues(IssueQuery(labelIds: [bug.id])).issues.map(\.identifier) == ["ENG-2"])
        #expect(try store.queryIssues(IssueQuery(labelIds: [])).issues.isEmpty)
    }

    @Test func combinesTextWithFilters() throws {
        let fixture = try Fixture()
        try fixture.issue("Login button broken", state: "Todo")
        try fixture.issue("Login copy tweak", state: "Done")
        let page = try fixture.store.queryIssues(IssueQuery(text: "login", stateCategories: [.unstarted]))
        #expect(page.issues.map(\.identifier) == ["ENG-1"])
        #expect(try fixture.store.queryIssues(IssueQuery(text: "%%")).issues.isEmpty)
    }

    @Test func pagesWithNextOffset() throws {
        let fixture = try Fixture()
        for index in 1...5 { try fixture.issue("Issue \(index)") }
        let first = try fixture.store.queryIssues(IssueQuery(order: .created, limit: 2))
        #expect(first.issues.map(\.identifier) == ["ENG-5", "ENG-4"])
        #expect(first.nextOffset == 2)
        let last = try fixture.store.queryIssues(IssueQuery(order: .created, limit: 2, offset: 4))
        #expect(last.issues.map(\.identifier) == ["ENG-1"])
        #expect(last.nextOffset == nil)
    }

    @Test func priorityOrderPutsNoPriorityLast() throws {
        let fixture = try Fixture()
        let none = try fixture.issue("None")
        let low = try fixture.issue("Low")
        let urgent = try fixture.issue("Urgent")
        _ = try fixture.store.updateIssue(low.id, IssuePatch(priority: .low), by: fixture.me.id)
        _ = try fixture.store.updateIssue(urgent.id, IssuePatch(priority: .urgent), by: fixture.me.id)
        let ordered = try fixture.store.queryIssues(IssueQuery(order: .priority)).issues.map(\.id)
        #expect(ordered == [urgent.id, low.id, none.id])
    }

    @Test func dueOrderPutsUndatedLast() throws {
        let fixture = try Fixture()
        let undated = try fixture.issue("Undated")
        let later = try fixture.issue("Later")
        let sooner = try fixture.issue("Sooner")
        _ = try fixture.store.updateIssue(later.id, IssuePatch(dueDate: .set(try #require(CalendarDate("2027-03-01")))), by: fixture.me.id)
        _ = try fixture.store.updateIssue(sooner.id, IssuePatch(dueDate: .set(try #require(CalendarDate("2027-01-01")))), by: fixture.me.id)
        #expect(try fixture.store.queryIssues(IssueQuery(order: .due)).issues.map(\.id) == [sooner.id, later.id, undated.id])
    }

    @Test func subIssuesCanBeHiddenOrSelected() throws {
        let fixture = try Fixture()
        let parent = try fixture.issue("Parent")
        let child = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Child", parentId: parent.id), by: fixture.me.id)
        #expect(try fixture.store.queryIssues(IssueQuery(includeSubIssues: false)).issues.map(\.id) == [parent.id])
        #expect(try fixture.store.queryIssues(IssueQuery(parentId: parent.id)).issues.map(\.id) == [child.id])
    }

    @Test func cycleProgressCountsByCategory() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let cycle = try store.createCycle(teamId: fixture.team.id, startsAt: Date(timeIntervalSince1970: 1_799_999_000), by: fixture.me.id)
        #expect(try store.activeCycle(teamId: fixture.team.id)?.id == cycle.id)
        for (title, state, points) in [("A", "Done", 3), ("B", "In Progress", 5), ("C", "Canceled", 8)] {
            let issue = try fixture.issue(title, state: state)
            _ = try store.updateIssue(issue.id, IssuePatch(estimate: .set(points), cycleId: .set(cycle.id)), by: fixture.me.id)
        }
        let progress = try store.cycleProgress(cycleId: cycle.id)
        #expect(progress.issueCount == 3)
        #expect(progress.completedCount == 1)
        #expect(progress.openCount == 1)
        #expect(progress.totalEstimate == 8)
        #expect(progress.completedEstimate == 3)
    }

    @Test func labelIdsArePerIssue() throws {
        let fixture = try Fixture()
        let bug = try fixture.store.createLabel(name: "bug", color: "#f00", teamId: nil, by: fixture.me.id)
        let first = try fixture.issue("First")
        let second = try fixture.issue("Second")
        _ = try fixture.store.addLabels([bug.id], to: first.id, by: fixture.me.id)
        let map = try fixture.store.labelIds(forIssues: [first.id, second.id])
        #expect(map[first.id] == [bug.id])
        #expect(map[second.id] == nil)
    }
}
