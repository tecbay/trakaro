import Foundation
import Testing
@testable import TrackaroCore

@Suite("Change feed")
struct FeedTests {
    @Test func startsAtHeadAndReturnsOnlyNewEvents() throws {
        let fixture = try Fixture()
        try fixture.issue("Before")
        let head = try fixture.store.feedHead()
        #expect(try fixture.store.feed(after: head).events.isEmpty)

        let issue = try fixture.issue("After")
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(priority: .high), by: fixture.me.id)
        try fixture.store.addComment(to: issue.id, body: "Note", by: fixture.me.id)
        let (events, next) = try fixture.store.feed(after: head)
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.issue.id == issue.id })
        if case .comment = events.last?.kind {} else { Issue.record("comment should come last") }
        #expect(try fixture.store.feed(after: next).events.isEmpty)
    }

    @Test func filtersByMemberKindAndExcludesTheCaller() throws {
        let fixture = try Fixture()
        let claude = try fixture.store.agent(named: "Claude Code")
        let cursor = try fixture.store.agent(named: "Cursor")
        let head = try fixture.store.feedHead()
        let issue = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Shared"), by: claude.id)
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(stateId: fixture.state("Todo").id), by: fixture.me.id)
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(priority: .low), by: cursor.id)

        let humans = try fixture.store.feed(after: head, memberKinds: [.user]).events
        #expect(humans.map(\.member.id) == [fixture.me.id])

        let notMine = try fixture.store.feed(after: head, excludingMember: claude.id).events
        #expect(notMine.map(\.member.name) == ["Me", "Cursor"])
    }

    @Test func filteredEventsStillAdvanceTheCursor() throws {
        let fixture = try Fixture()
        let claude = try fixture.store.agent(named: "Claude Code")
        let head = try fixture.store.feedHead()
        _ = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Agent only"), by: claude.id)
        let (events, next) = try fixture.store.feed(after: head, memberKinds: [.user])
        #expect(events.isEmpty)
        #expect(next != head)
        #expect(try fixture.store.feed(after: next).events.isEmpty)
    }

    @Test func cursorRoundTripsAsText() throws {
        let cursor = FeedCursor(activity: 12, comment: 3)
        #expect(FeedCursor(cursor.description) == cursor)
        #expect(FeedCursor("12") == nil)
        #expect(FeedCursor(" 4:5\n") == FeedCursor(activity: 4, comment: 5))
    }
}
