import Foundation
import Testing
@testable import TrackaroCore

@Suite("Recent changes by kind")
struct RecentChangeTests {
    @Test func listsIssuesAgentsTouchedNewestFirst() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let claude = try store.agent(named: "Claude Code")
        let cursor = try store.agent(named: "Cursor")
        let first = try fixture.issue("Mine only")
        let second = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Claude made this"), by: claude.id)
        let third = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Cursor made this"), by: cursor.id)
        _ = try store.updateIssue(second.id, IssuePatch(priority: .high), by: claude.id)
        _ = try store.updateIssue(first.id, IssuePatch(priority: .low), by: fixture.me.id)

        let changes = try store.recentChanges(by: .agent)
        #expect(changes.map(\.issue.id) == [second.id, third.id])
        #expect(changes.map(\.member.name) == ["Claude Code", "Cursor"])
        #expect(changes.first?.issue.priority == .high)
    }

    @Test func reportsTheLatestAgentAndHidesArchived() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let claude = try store.agent(named: "Claude Code")
        let cursor = try store.agent(named: "Cursor")
        let shared = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Shared"), by: claude.id)
        _ = try store.updateIssue(shared.id, IssuePatch(priority: .urgent), by: cursor.id)
        let gone = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Gone"), by: claude.id)
        _ = try store.archiveIssue(gone.id, by: fixture.me.id)

        let changes = try store.recentChanges(by: .agent)
        #expect(changes.map(\.issue.id) == [shared.id])
        #expect(changes.first?.member.name == "Cursor")
    }
}
