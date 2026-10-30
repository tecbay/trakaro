import Foundation
import Testing
@testable import TrackaroCore
@testable import TrackaroKit

@Suite("Board")
struct BoardTests {
    private func items(_ fixture: KitFixture) throws -> [IssueRowItem] {
        let snapshot = try fixture.store.snapshot()
        return try fixture.store.queryIssues(IssueQuery()).issues.map {
            IssueRowBuilder.item($0, snapshot: snapshot, labelIds: [], parentIdentifier: nil)
        }
    }

    @Test func stateColumnsIncludeEmptyStatesInWorkflowOrder() throws {
        let fixture = try KitFixture()
        _ = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Doing", stateId: try fixture.state("In Progress").id), by: fixture.me.id)
        let columns = BoardBuilder.stateColumns(try items(fixture), states: try fixture.store.states(teamId: fixture.team.id))
        #expect(columns.map(\.title) == DefaultWorkflow.states.map(\.name))
        #expect(columns.first { $0.title == "In Progress" }?.cards.map(\.title) == ["Doing"])
        #expect(columns.allSatisfy { $0.stateId != nil })
    }

    @Test func categoryColumnsSpanTeamsAndHideEmptyExtras() throws {
        let fixture = try KitFixture()
        let ops = try fixture.store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        let opsStarted = try #require(try fixture.store.states(teamId: ops.id).first { $0.category == .started })
        _ = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Eng", stateId: try fixture.state("In Progress").id), by: fixture.me.id)
        _ = try fixture.store.createIssue(NewIssue(teamId: ops.id, title: "Ops", stateId: opsStarted.id), by: fixture.me.id)
        let columns = BoardBuilder.categoryColumns(try items(fixture), snapshot: try fixture.store.snapshot())
        #expect(columns.map(\.category) == BoardBuilder.coreCategories)
        #expect(columns.first { $0.category == .started }?.cards.count == 2)
        #expect(columns.allSatisfy { $0.stateId == nil })
    }

    @Test func categoryDropsResolveToEachIssuesOwnTeam() throws {
        let fixture = try KitFixture()
        let ops = try fixture.store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        let opsIssue = try fixture.store.createIssue(NewIssue(teamId: ops.id, title: "Ops"), by: fixture.me.id)
        let snapshot = try fixture.store.snapshot()
        let done = try #require(BoardBuilder.categoryColumns([], snapshot: snapshot).first { $0.category == .completed })
        let target = try #require(BoardDrop.targetState(for: opsIssue, column: done, snapshot: snapshot))
        #expect(target.teamId == ops.id)
        #expect(target.category == .completed)
    }

    @Test func categoryDropKeepsAStateAlreadyInThatCategory() throws {
        let fixture = try KitFixture()
        let canceledStates = try fixture.store.states(teamId: fixture.team.id).filter { $0.category == .canceled }
        let duplicate = try #require(canceledStates.last)
        let issue = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Dup", stateId: duplicate.id), by: fixture.me.id)
        let snapshot = try fixture.store.snapshot()
        let column = BoardColumn(id: "canceled", title: "Canceled", category: .canceled, color: "#999", stateId: nil, cards: [])
        #expect(BoardDrop.targetState(for: issue, column: column, snapshot: snapshot)?.id == duplicate.id)
    }

    @Test func stateColumnsRejectOtherTeams() throws {
        let fixture = try KitFixture()
        let ops = try fixture.store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        let opsIssue = try fixture.store.createIssue(NewIssue(teamId: ops.id, title: "Ops"), by: fixture.me.id)
        let snapshot = try fixture.store.snapshot()
        let engColumn = try #require(BoardBuilder.stateColumns([], states: try fixture.store.states(teamId: fixture.team.id)).first)
        #expect(BoardDrop.targetState(for: opsIssue, column: engColumn, snapshot: snapshot) == nil)
    }

    @Test func dropsPositionCardsAndMoveThroughTheStore() throws {
        let fixture = try KitFixture()
        let store = fixture.store
        let todo = try fixture.state("Todo")
        for title in ["A", "B"] {
            _ = try store.createIssue(NewIssue(teamId: fixture.team.id, title: title, stateId: todo.id), by: fixture.me.id)
        }
        let mover = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Mover"), by: fixture.me.id)
        func todoColumn() throws -> BoardColumn {
            try #require(BoardBuilder.stateColumns(try items(fixture), states: try store.states(teamId: fixture.team.id)).first { $0.stateId == todo.id })
        }
        #expect(try todoColumn().cards.map(\.title) == ["B", "A"])

        let toEnd = BoardDrop.move(issue: mover, target: todo, column: try todoColumn(), beforeCard: nil)
        #expect(toEnd.stateId == todo.id)
        _ = try store.moveIssue(mover.id, toEnd, by: fixture.me.id)
        #expect(try todoColumn().cards.map(\.title) == ["B", "A", "Mover"])

        let firstCard = try #require(try todoColumn().cards.first)
        let moved = try store.issue(mover.id)
        let toTop = BoardDrop.move(issue: moved, target: todo, column: try todoColumn(), beforeCard: firstCard.id)
        #expect(toTop.stateId == nil)
        _ = try store.moveIssue(mover.id, toTop, by: fixture.me.id)
        #expect(try todoColumn().cards.map(\.title) == ["Mover", "B", "A"])

        let ontoItself = BoardDrop.move(issue: moved, target: todo, column: try todoColumn(), beforeCard: mover.id)
        #expect(ontoItself.beforeIssue == nil && ontoItself.afterIssue == nil)
    }
}
