import Foundation
import Testing
@testable import TrackaroCore

@Suite("Project and cycle progress")
struct ProgressTests {
    @Test func projectProgressSplitsByMilestoneAndIgnoresCanceledScope() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let project = try store.createProject(name: "Launch", by: fixture.me.id)
        let beta = try store.createMilestone(projectId: project.id, name: "Beta", by: fixture.me.id)
        let ga = try store.createMilestone(projectId: project.id, name: "GA", by: fixture.me.id)
        let done = try fixture.issue("Done", state: "Done")
        let doing = try fixture.issue("Doing", state: "In Progress")
        let dropped = try fixture.issue("Dropped", state: "Canceled")
        let loose = try fixture.issue("Loose")
        try fixture.issue("Elsewhere", state: "Done")
        _ = try store.updateIssue(done.id, IssuePatch(estimate: .set(3), projectId: .set(project.id), milestoneId: .set(beta.id)), by: fixture.me.id)
        _ = try store.updateIssue(doing.id, IssuePatch(estimate: .set(2), projectId: .set(project.id), milestoneId: .set(beta.id)), by: fixture.me.id)
        _ = try store.updateIssue(dropped.id, IssuePatch(estimate: .set(8), projectId: .set(project.id)), by: fixture.me.id)
        _ = try store.updateIssue(loose.id, IssuePatch(projectId: .set(project.id)), by: fixture.me.id)

        let progress = try store.projectProgress(projectId: project.id)
        #expect(progress.overall.issueCount == 4)
        #expect(progress.overall.completedCount == 1)
        #expect(progress.overall.startedCount == 1)
        #expect(progress.overall.openCount == 2)
        #expect(abs(progress.overall.fraction - 1.0 / 3.0) < 0.0001)
        #expect(progress.overall.totalEstimate == 5)
        #expect(progress.overall.completedEstimate == 3)
        #expect(progress.milestones.map(\.milestone.name) == ["Beta", "GA"])
        #expect(progress.milestones[0].progress.fraction == 0.5)
        #expect(progress.milestones.first { $0.milestone.id == ga.id }?.progress.issueCount == 0)
        #expect(try store.projectsProgress()[project.id] == progress.overall)
    }

    @Test func projectUpdatesValidateAndRecord() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let project = try store.createProject(name: "Launch", targetDate: CalendarDate("2027-03-01"), by: fixture.me.id)
        let before = try store.latestChangeSeq()
        let updated = try store.updateProject(project.id, ProjectPatch(
            status: .inProgress, health: .atRisk, leadId: .set(fixture.me.id), startDate: .set(try #require(CalendarDate("2027-01-01")))
        ), by: fixture.me.id)
        #expect(updated.status == .inProgress)
        #expect(updated.health == .atRisk)
        #expect(updated.leadId == fixture.me.id)
        #expect(updated.name == "Launch")
        #expect(try store.latestChangeSeq() == before + 1)
        #expect(throws: TrackaroError.self) {
            try store.updateProject(project.id, ProjectPatch(startDate: .set(try #require(CalendarDate("2027-04-01")))), by: fixture.me.id)
        }
        #expect(throws: TrackaroError.self) { try store.updateProject(project.id, ProjectPatch(name: "  "), by: fixture.me.id) }
        #expect(try store.updateProject(project.id, ProjectPatch(leadId: .clear), by: fixture.me.id).leadId == nil)
    }

    @Test func completingACycleEndsItAndFindsTheNextOne() throws {
        let fixture = try Fixture()
        let store = fixture.store
        let first = try store.createCycle(teamId: fixture.team.id, by: fixture.me.id)
        let second = try store.createCycle(teamId: fixture.team.id, by: fixture.me.id)
        let open = try fixture.issue("Open")
        let finished = try fixture.issue("Finished", state: "Done")
        for issue in [open, finished] { _ = try store.updateIssue(issue.id, IssuePatch(cycleId: .set(first.id)), by: fixture.me.id) }

        #expect(try store.cyclesProgress(teamId: fixture.team.id)[first.id]?.openCount == 1)
        #expect(try store.nextCycle(after: first)?.id == second.id)
        #expect(try store.nextCycle(after: second) == nil)

        let completed = try store.completeCycle(first.id, by: fixture.me.id)
        #expect(completed.completedAt != nil)
        #expect(try store.activeCycle(teamId: fixture.team.id)?.id != first.id)
        #expect(throws: TrackaroError.self) { try store.completeCycle(first.id, by: fixture.me.id) }
    }
}
