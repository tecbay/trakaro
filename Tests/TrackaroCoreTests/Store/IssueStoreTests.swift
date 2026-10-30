import Foundation
import Testing
@testable import TrackaroCore

@Suite("Teams and identifiers")
struct TeamTests {
    @Test func newTeamGetsDefaultWorkflowInOrder() throws {
        let fixture = try Fixture()
        let states = try fixture.store.states(teamId: fixture.team.id)
        #expect(states.map(\.name) == DefaultWorkflow.states.map(\.name))
        #expect(states.map(\.position) == Array(0..<DefaultWorkflow.states.count))
    }

    @Test func teamKeyIsUppercasedAndValidated() throws {
        let fixture = try Fixture()
        let ops = try fixture.store.createTeam(key: "ops", name: "Operations", by: fixture.me.id)
        #expect(ops.key == "OPS")
        #expect(throws: TrackaroError.self) { try fixture.store.createTeam(key: "x", name: "Bad", by: fixture.me.id) }
    }

    @Test func duplicateKeyConflictsCaseInsensitively() throws {
        let fixture = try Fixture()
        #expect(throws: TrackaroError.conflict(message: "A team with key ENG already exists.", candidates: [])) {
            try fixture.store.createTeam(key: "eng", name: "Again", by: fixture.me.id)
        }
    }

    @Test func teamResolvesByKeyNameOrId() throws {
        let fixture = try Fixture()
        #expect(try fixture.store.team("eng").id == fixture.team.id)
        #expect(try fixture.store.team("engineering").id == fixture.team.id)
        #expect(try fixture.store.team(fixture.team.id).id == fixture.team.id)
        #expect(throws: TrackaroError.notFound(entity: "team", reference: "nope")) { try fixture.store.team("nope") }
    }

    @Test func identifiersCountPerTeam() throws {
        let fixture = try Fixture()
        let ops = try fixture.store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        #expect(try fixture.issue("One").identifier == "ENG-1")
        #expect(try fixture.issue("Two").identifier == "ENG-2")
        #expect(try fixture.issue("Ops one", teamId: ops.id).identifier == "OPS-1")
        #expect(try fixture.issue("Three").identifier == "ENG-3")
    }

    @Test func localUserIsCreatedOnce() throws {
        let fixture = try Fixture()
        #expect(try fixture.store.localUser().id == fixture.me.id)
        let claude = try fixture.store.agent(named: "Claude", clientName: "claude-code")
        #expect(try fixture.store.agent(named: "claude").id == claude.id)
        #expect(claude.kind == .agent)
    }
}

@Suite("Creating issues")
struct CreateIssueTests {
    @Test func defaultsToBacklogAtTopOfColumn() throws {
        let fixture = try Fixture()
        let first = try fixture.issue("First")
        try fixture.issue("Second")
        #expect(first.stateId == (try fixture.state("Backlog").id))
        #expect(try fixture.column("Backlog") == ["ENG-2", "ENG-1"])
    }

    @Test func creatingInProgressStampsStart() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Hot fix", state: "In Progress")
        #expect(issue.startedAt != nil)
        #expect(issue.completedAt == nil)
    }

    @Test func titleIsTrimmedAndRequired() throws {
        let fixture = try Fixture()
        #expect(try fixture.issue("  Spaced  ").title == "Spaced")
        #expect(throws: TrackaroError.invalid(field: "title", message: "A title is required.")) {
            try fixture.issue("   ")
        }
    }

    @Test func createsWithEveryOptionalField() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let label = try store.createLabel(name: "bug", color: "#ff0000", teamId: fixture.team.id, by: fixture.me.id)
        let project = try store.createProject(name: "Launch", by: fixture.me.id)
        let milestone = try store.createMilestone(projectId: project.id, name: "Beta", by: fixture.me.id)
        let cycle = try store.createCycle(teamId: fixture.team.id, by: fixture.me.id)
        let parent = try fixture.issue("Parent")
        let due = try #require(CalendarDate("2026-12-01"))
        let issue = try store.createIssue(NewIssue(
            teamId: fixture.team.id, title: "Child", description: "Body", stateId: fixture.state("Todo").id,
            priority: .high, estimate: 3, dueDate: due, assigneeId: fixture.me.id, parentId: parent.id,
            milestoneId: milestone.id, cycleId: cycle.id, labelIds: [label.id]
        ), by: fixture.me.id)
        #expect(issue.priority == .high)
        #expect(issue.estimate == 3)
        #expect(issue.dueDate == due)
        #expect(issue.parentId == parent.id)
        #expect(issue.projectId == project.id)
        #expect(issue.milestoneId == milestone.id)
        #expect(issue.cycleId == cycle.id)
        #expect(try store.labels(forIssue: issue.id).map(\.name) == ["bug"])
        #expect(try store.issue("eng-2").id == issue.id)
        #expect(try store.activity(issueId: issue.id).map(\.field) == [.created])
    }

    @Test func archivedTeamRejectsNewIssues() throws {
        let fixture = try Fixture()
        try fixture.store.writer.write { db in
            try db.execute(sql: "UPDATE team SET archivedAt = CURRENT_TIMESTAMP WHERE id = ?", arguments: [fixture.team.id])
        }
        #expect(throws: TrackaroError.invalid(field: "team", message: "ENG is archived.")) { try fixture.issue("Late") }
    }
}

@Suite("Updating issues")
struct UpdateIssueTests {
    @Test func reportsChangedFieldsAndBumpsVersion() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Original")
        let change = try fixture.store.updateIssue(issue.id, IssuePatch(title: "Renamed", priority: .urgent), by: fixture.me.id)
        #expect(change.changed == [.title, .priority])
        #expect(change.issue.version == issue.version + 1)
        #expect(change.issue.updatedAt > issue.updatedAt)
        let activity = try fixture.store.activity(issueId: issue.id)
        #expect(activity.map(\.field) == [.created, .title, .priority])
        #expect(activity.last?.fromValue == "\"none\"")
        #expect(activity.last?.toValue == "\"urgent\"")
    }

    @Test func unchangedValuesAreANoOp() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Same")
        let change = try fixture.store.updateIssue(issue.identifier, IssuePatch(title: "Same", priority: Priority.none), by: fixture.me.id)
        #expect(change.changed.isEmpty)
        #expect(try fixture.store.issue(issue.id).version == issue.version)
    }

    @Test func clearRemovesAValueAndNilLeavesItAlone() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Assigned")
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(estimate: .set(5), assigneeId: .set(fixture.me.id)), by: fixture.me.id)
        let cleared = try fixture.store.updateIssue(issue.id, IssuePatch(assigneeId: .clear), by: fixture.me.id)
        #expect(cleared.issue.assigneeId == nil)
        #expect(cleared.issue.estimate == 5)
    }

    @Test func stateChangeFollowsTimestampRules() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Lifecycle")
        let started = try fixture.store.updateIssue(issue.id, IssuePatch(stateId: fixture.state("In Progress").id), by: fixture.me.id).issue
        let startedAt = try #require(started.startedAt)
        let done = try fixture.store.updateIssue(issue.id, IssuePatch(stateId: fixture.state("Done").id), by: fixture.me.id).issue
        #expect(done.startedAt == startedAt)
        #expect(done.completedAt != nil)
        let reopened = try fixture.store.updateIssue(issue.id, IssuePatch(stateId: fixture.state("Backlog").id), by: fixture.me.id).issue
        #expect(reopened.startedAt == nil)
        #expect(reopened.completedAt == nil)
        #expect(reopened.stateEnteredAt > done.stateEnteredAt)
    }

    @Test func stateFromAnotherTeamIsRejected() throws {
        let fixture = try Fixture()
        let ops = try fixture.store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        let issue = try fixture.issue("Mine")
        let foreign = try fixture.state("Todo", in: ops.id)
        #expect(throws: TrackaroError.self) {
            try fixture.store.updateIssue(issue.id, IssuePatch(stateId: foreign.id), by: fixture.me.id)
        }
    }

    @Test func expectationGuardsAgainstStaleWrites() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Contested")
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(priority: .high), by: fixture.me.id)
        #expect(throws: TrackaroError.conflict(message: "ENG-1 changed since it was read: priority.", candidates: [])) {
            try fixture.store.updateIssue(issue.id, IssuePatch(priority: .low), expecting: IssuePatch(priority: Priority.none), by: fixture.me.id)
        }
        let undone = try fixture.store.updateIssue(issue.id, IssuePatch(priority: Priority.none), expecting: IssuePatch(priority: .high), by: fixture.me.id)
        #expect(undone.issue.priority == Priority.none)
    }

    @Test func expectationOnAnotherFieldDoesNotBlock() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Two editors")
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(title: "Edited elsewhere"), by: fixture.me.id)
        let change = try fixture.store.updateIssue(issue.id, IssuePatch(priority: .low), expecting: IssuePatch(priority: Priority.none), by: fixture.me.id)
        #expect(change.changed == [.priority])
    }

    @Test func parentCyclesAreRejected() throws {
        let fixture = try Fixture()
        let a = try fixture.issue("A")
        let b = try fixture.issue("B")
        let c = try fixture.issue("C")
        _ = try fixture.store.updateIssue(b.id, IssuePatch(parentId: .set(a.id)), by: fixture.me.id)
        _ = try fixture.store.updateIssue(c.id, IssuePatch(parentId: .set(b.id)), by: fixture.me.id)
        #expect(throws: TrackaroError.invalid(field: "parent", message: "That would make the issue its own ancestor.")) {
            try fixture.store.updateIssue(a.id, IssuePatch(parentId: .set(c.id)), by: fixture.me.id)
        }
        #expect(throws: TrackaroError.invalid(field: "parent", message: "An issue cannot be its own parent.")) {
            try fixture.store.updateIssue(a.id, IssuePatch(parentId: .set(a.id)), by: fixture.me.id)
        }
        #expect(try fixture.store.children(of: a.id).map(\.id) == [b.id])
    }

    @Test func milestoneSetsProjectAndProjectChangeClearsMilestone() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let launch = try store.createProject(name: "Launch", by: fixture.me.id)
        let other = try store.createProject(name: "Other", by: fixture.me.id)
        let beta = try store.createMilestone(projectId: launch.id, name: "Beta", by: fixture.me.id)
        let issue = try fixture.issue("Ship it")

        let withMilestone = try store.updateIssue(issue.id, IssuePatch(milestoneId: .set(beta.id)), by: fixture.me.id)
        #expect(withMilestone.issue.projectId == launch.id)
        #expect(withMilestone.changed == [.project, .milestone])

        let otherMilestone = try store.createMilestone(projectId: other.id, name: "GA", by: fixture.me.id)
        #expect(throws: TrackaroError.self) {
            try store.updateIssue(issue.id, IssuePatch(milestoneId: .set(otherMilestone.id)), by: fixture.me.id)
        }

        let moved = try store.updateIssue(issue.id, IssuePatch(projectId: .set(other.id)), by: fixture.me.id)
        #expect(moved.issue.milestoneId == nil)
        #expect(moved.changed == [.project, .milestone])
    }

    @Test func cycleMustBelongToTheIssuesTeam() throws {
        let fixture = try Fixture()
        let ops = try fixture.store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        let opsCycle = try fixture.store.createCycle(teamId: ops.id, by: fixture.me.id)
        let issue = try fixture.issue("Planned")
        #expect(throws: TrackaroError.invalid(field: "cycle", message: "That cycle belongs to another team.")) {
            try fixture.store.updateIssue(issue.id, IssuePatch(cycleId: .set(opsCycle.id)), by: fixture.me.id)
        }
    }

    @Test func estimateMustBeInRange() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Sized")
        #expect(throws: TrackaroError.self) {
            try fixture.store.updateIssue(issue.id, IssuePatch(estimate: .set(-1)), by: fixture.me.id)
        }
    }

    @Test func archiveAndUnarchive() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Old")
        #expect(try fixture.store.archiveIssue(issue.id, by: fixture.me.id).changed == [.archived])
        #expect(try fixture.store.archiveIssue(issue.id, by: fixture.me.id).changed.isEmpty)
        #expect(try fixture.store.issues(teamId: fixture.team.id).isEmpty)
        #expect(try fixture.store.issues(teamId: fixture.team.id, includeArchived: true).count == 1)
        #expect(try fixture.store.unarchiveIssue(issue.id, by: fixture.me.id).issue.archivedAt == nil)
    }

    @Test func unknownMemberIsRejected() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Who")
        #expect(throws: TrackaroError.notFound(entity: "member", reference: "ghost")) {
            try fixture.store.updateIssue(issue.id, IssuePatch(title: "Hi"), by: "ghost")
        }
    }
}

@Suite("Moving issues")
struct MoveIssueTests {
    @Test func reordersWithinAColumn() throws {
        let fixture = try Fixture()
        try fixture.issue("One")
        try fixture.issue("Two")
        try fixture.issue("Three")
        #expect(try fixture.column("Backlog") == ["ENG-3", "ENG-2", "ENG-1"])

        let below = try fixture.store.moveIssue("ENG-3", IssueMove(afterIssue: "ENG-1"), by: fixture.me.id)
        #expect(below.changed == [.position])
        #expect(try fixture.column("Backlog") == ["ENG-2", "ENG-1", "ENG-3"])

        _ = try fixture.store.moveIssue("ENG-3", IssueMove(beforeIssue: "ENG-2"), by: fixture.me.id)
        #expect(try fixture.column("Backlog") == ["ENG-3", "ENG-2", "ENG-1"])

        _ = try fixture.store.moveIssue("ENG-1", IssueMove(afterIssue: "ENG-3", beforeIssue: "ENG-2"), by: fixture.me.id)
        #expect(try fixture.column("Backlog") == ["ENG-3", "ENG-1", "ENG-2"])
    }

    @Test func movingRepeatedlyIntoTheSameGapStaysOrdered() throws {
        let fixture = try Fixture()
        for index in 1...6 { try fixture.issue("Issue \(index)") }
        for _ in 0..<40 {
            let column = try fixture.column("Backlog")
            _ = try fixture.store.moveIssue(column[5], IssueMove(afterIssue: column[0], beforeIssue: column[1]), by: fixture.me.id)
            let after = try fixture.column("Backlog")
            #expect(after[1] == column[5])
        }
        #expect(try fixture.column("Backlog").count == 6)
    }

    @Test func changingStateLandsOnTopOfTheNewColumn() throws {
        let fixture = try Fixture()
        try fixture.issue("Existing", state: "Todo")
        try fixture.issue("Mover")
        let change = try fixture.store.moveIssue("ENG-2", IssueMove(stateId: fixture.state("Todo").id), by: fixture.me.id)
        #expect(change.changed == [.state, .position])
        #expect(try fixture.column("Todo") == ["ENG-2", "ENG-1"])
    }

    @Test func neighboursMustShareTheColumn() throws {
        let fixture = try Fixture()
        try fixture.issue("Backlog item")
        try fixture.issue("Todo item", state: "Todo")
        #expect(throws: TrackaroError.invalid(field: "position", message: "ENG-2 is in a different column.")) {
            try fixture.store.moveIssue("ENG-1", IssueMove(afterIssue: "ENG-2"), by: fixture.me.id)
        }
        #expect(throws: TrackaroError.invalid(field: "position", message: "An issue cannot be placed next to itself.")) {
            try fixture.store.moveIssue("ENG-1", IssueMove(afterIssue: "ENG-1"), by: fixture.me.id)
        }
    }

    @Test func changingTeamReissuesIdentifierAndKeepsAlias() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let ops = try store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        let engLabel = try store.createLabel(name: "frontend", color: "#00f", teamId: fixture.team.id, by: fixture.me.id)
        let globalLabel = try store.createLabel(name: "urgent-ish", color: "#f00", teamId: nil, by: fixture.me.id)
        let cycle = try store.createCycle(teamId: fixture.team.id, by: fixture.me.id)
        try fixture.issue("Filler")
        let issue = try fixture.issue("Traveller", state: "In Progress")
        _ = try store.updateIssue(issue.id, IssuePatch(cycleId: .set(cycle.id)), by: fixture.me.id)
        _ = try store.addLabels([engLabel.id, globalLabel.id], to: issue.id, by: fixture.me.id)

        let change = try store.moveIssue("ENG-2", IssueMove(teamId: ops.id), by: fixture.me.id)

        #expect(change.issue.identifier == "OPS-1")
        #expect(change.issue.cycleId == nil)
        #expect(change.issue.stateId == (try fixture.state("In Progress", in: ops.id).id))
        #expect(change.issue.startedAt == issue.startedAt)
        #expect(change.changed == [.team, .cycle, .labels, .state])
        #expect(try store.labels(forIssue: issue.id).map(\.name) == ["urgent-ish"])
        #expect(try store.issue("ENG-2").id == issue.id)
        #expect(try store.issue("ops-1").id == issue.id)
        #expect(try fixture.issue("Next").identifier == "ENG-3")
    }
}

@Suite("Labels, relations and comments")
struct LinkTests {
    @Test func addRemoveAndSetLabels() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let bug = try store.createLabel(name: "bug", color: "#f00", teamId: nil, by: fixture.me.id)
        let ui = try store.createLabel(name: "ui", color: "#0f0", teamId: fixture.team.id, by: fixture.me.id)
        let issue = try fixture.issue("Labelled")
        #expect(try store.addLabels([bug.id, ui.id, bug.id], to: issue.id, by: fixture.me.id).changed == [.labels])
        #expect(try store.addLabels([bug.id], to: issue.id, by: fixture.me.id).changed.isEmpty)
        _ = try store.removeLabels([bug.id], from: issue.id, by: fixture.me.id)
        #expect(try store.labels(forIssue: issue.id).map(\.name) == ["ui"])
        _ = try store.setLabels([bug.id], on: issue.id, by: fixture.me.id)
        #expect(try store.labels(forIssue: issue.id).map(\.name) == ["bug"])
        #expect(try store.labels(teamId: fixture.team.id).map(\.name) == ["bug", "ui"])
    }

    @Test func labelsFromAnotherTeamAreRejected() throws {
        let fixture = try Fixture()
        let ops = try fixture.store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        let opsLabel = try fixture.store.createLabel(name: "infra", color: "#999", teamId: ops.id, by: fixture.me.id)
        let issue = try fixture.issue("Eng issue")
        #expect(throws: TrackaroError.invalid(field: "labels", message: "infra belongs to another team.")) {
            try fixture.store.addLabels([opsLabel.id], to: issue.id, by: fixture.me.id)
        }
    }

    @Test func relationsWriteTheirInverseAndDriveBlockedState() throws {
        let fixture = try Fixture()
        let store = fixture.store
        try fixture.issue("Blocker")
        try fixture.issue("Blocked")
        try store.setRelation(.blocks, from: "ENG-1", to: "ENG-2", by: fixture.me.id)
        try store.setRelation(.blocks, from: "ENG-1", to: "ENG-2", by: fixture.me.id)
        #expect(try store.relations(of: "ENG-1").map(\.type) == [.blocks])
        #expect(try store.relations(of: "ENG-2").map(\.type) == [.blockedBy])
        #expect(try store.isBlocked("ENG-2"))
        #expect(try !store.isBlocked("ENG-1"))

        _ = try store.updateIssue("ENG-1", IssuePatch(stateId: fixture.state("Done").id), by: fixture.me.id)
        #expect(try !store.isBlocked("ENG-2"))

        try store.removeRelation(.blockedBy, from: "ENG-2", to: "ENG-1", by: fixture.me.id)
        #expect(try store.relations(of: "ENG-1").isEmpty)
        #expect(try store.relations(of: "ENG-2").isEmpty)
        #expect(throws: TrackaroError.self) { try store.setRelation(.related, from: "ENG-1", to: "eng-1", by: fixture.me.id) }
    }

    @Test func commentsThreadOnlyWithinTheirIssue() throws {
        let fixture = try Fixture()
        let store = fixture.store
        try fixture.issue("Discussed")
        try fixture.issue("Elsewhere")
        let root = try store.addComment(to: "ENG-1", body: "  First thoughts  ", by: fixture.me.id)
        #expect(root.body == "First thoughts")
        let claude = try store.agent(named: "Claude")
        try store.addComment(to: "ENG-1", body: "Agreed", replyingTo: root.id, by: claude.id)
        #expect(try store.comments(on: "ENG-1").map(\.body) == ["First thoughts", "Agreed"])
        #expect(throws: TrackaroError.notFound(entity: "comment", reference: root.id)) {
            try store.addComment(to: "ENG-2", body: "Wrong thread", replyingTo: root.id, by: fixture.me.id)
        }
        #expect(throws: TrackaroError.self) { try store.addComment(to: "ENG-1", body: "   ", by: fixture.me.id) }
    }
}

@Suite("Search and change log")
struct SearchAndChangeLogTests {
    @Test func prefixSearchAcrossTitleAndDescription() throws {
        let fixture = try Fixture()
        let store = fixture.store
        try fixture.issue("Authentication token refresh")
        _ = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Settings page", description: "Users cannot refresh avatars"), by: fixture.me.id)
        try fixture.issue("Unrelated")
        #expect(try store.searchIssues("auth tok").map(\.identifier) == ["ENG-1"])
        #expect(Set(try store.searchIssues("refresh").map(\.identifier)) == ["ENG-1", "ENG-2"])
        #expect(try store.searchIssues("   ").isEmpty)
        #expect(try store.searchIssues("\"*()").isEmpty)
    }

    @Test func titleMatchesOutrankDescriptionMatches() throws {
        let fixture = try Fixture()
        _ = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Misc", description: "mentions keyboard once"), by: fixture.me.id)
        try fixture.issue("Keyboard shortcuts")
        #expect(try fixture.store.searchIssues("keyboard").map(\.identifier) == ["ENG-2", "ENG-1"])
    }

    @Test func identifierMatchComesFirst() throws {
        let fixture = try Fixture()
        for index in 1...12 { try fixture.issue("Issue mentioning ENG \(index)") }
        #expect(try fixture.store.searchIssues("eng-12").first?.identifier == "ENG-12")
    }

    @Test func indexFollowsEditsAndArchiving() throws {
        let fixture = try Fixture()
        let issue = try fixture.issue("Old wording")
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(title: "Fresh wording"), by: fixture.me.id)
        #expect(try fixture.store.searchIssues("old").isEmpty)
        #expect(try fixture.store.searchIssues("fresh").count == 1)
        _ = try fixture.store.archiveIssue(issue.id, by: fixture.me.id)
        #expect(try fixture.store.searchIssues("fresh").isEmpty)
        #expect(try fixture.store.searchIssues("fresh", includeArchived: true).count == 1)
    }

    @Test func everyWriteAppendsToTheChangeLog() throws {
        let fixture = try Fixture()
        let start = try fixture.store.latestChangeSeq()
        let issue = try fixture.issue("Logged")
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(priority: .low), by: fixture.me.id)
        _ = try fixture.store.updateIssue(issue.id, IssuePatch(priority: .low), by: fixture.me.id)
        _ = try fixture.store.archiveIssue(issue.id, by: fixture.me.id)
        let changes = try fixture.store.changes(since: start)
        #expect(changes.map(\.action) == [.insert, .update, .archive])
        #expect(changes.allSatisfy { $0.modelId == issue.id && $0.memberId == fixture.me.id })
        #expect(zip(changes, changes.dropFirst()).allSatisfy { ($0.seq ?? 0) < ($1.seq ?? 0) })
        #expect(changes.last?.payload?.contains("\"archivedAt\"") == true)
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test func dataSurvivesReopeningTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trackaro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("trackaro.sqlite")
        do {
            let store = try TrackaroStore.open(at: url)
            let me = try store.localUser()
            let team = try store.createTeam(key: "ENG", name: "Engineering", by: me.id)
            _ = try store.createIssue(NewIssue(teamId: team.id, title: "Persist me", dueDate: CalendarDate("2027-01-15")), by: me.id)
        }
        let reopened = try TrackaroStore.open(at: url)
        let issue = try reopened.issue("ENG-1")
        #expect(issue.title == "Persist me")
        #expect(issue.dueDate?.description == "2027-01-15")
        #expect(try reopened.searchIssues("persist").count == 1)
    }
}
