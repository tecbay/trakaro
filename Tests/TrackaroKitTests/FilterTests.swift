import Foundation
import Testing
@testable import TrackaroCore
@testable import TrackaroKit

@Suite("Filters")
struct FilterTests {
    @Test func statusOptionsCoverEveryTeamWithThatName() throws {
        let fixture = try KitFixture()
        let ops = try fixture.store.createTeam(key: "OPS", name: "Operations", by: fixture.me.id)
        let snapshot = try fixture.store.snapshot()

        let everywhere = FilterCatalog.options(snapshot: snapshot, teamId: nil, userId: fixture.me.id)
        let inProgress = try #require(everywhere.first { $0.dimension == .status && $0.title == "In Progress" })
        #expect(inProgress.values.count == 2)
        #expect(everywhere.filter { $0.dimension == .team }.map(\.title) == ["Engineering", "Operations"])
        #expect(everywhere.first { $0.dimension == .assignee && $0.values == [fixture.me.id] }?.title.hasSuffix("(you)") == true)
        #expect(!everywhere.contains { $0.dimension == .project })

        let inTeam = FilterCatalog.options(snapshot: snapshot, teamId: ops.id, userId: fixture.me.id)
        #expect(inTeam.first { $0.dimension == .status && $0.title == "In Progress" }?.values.count == 1)
        #expect(!inTeam.contains { $0.dimension == .team })

        let issue = try fixture.store.createIssue(NewIssue(teamId: ops.id, title: "Deploy", stateId: inTeam.first { $0.title == "In Progress" }?.values.first), by: fixture.me.id)
        let filtered = inProgress.toggled(in: IssueFilter())
        #expect(try fixture.store.queryIssues(filtered.applied(to: IssueQuery())).issues.map(\.id) == [issue.id])
    }

    @Test func togglingSwitchesWholeOptionsAndChipsNameThem() throws {
        let fixture = try KitFixture()
        let snapshot = try fixture.store.snapshot()
        let options = FilterCatalog.options(snapshot: snapshot, teamId: fixture.team.id, userId: fixture.me.id)
        let urgent = try #require(options.first { $0.dimension == .priority && $0.title == "Urgent" })
        let noPriority = try #require(options.first { $0.dimension == .priority && $0.title == "No priority" })
        let me = try #require(options.first { $0.dimension == .assignee && $0.values == [fixture.me.id] })
        let unassigned = try #require(options.first { $0.dimension == .assignee && $0.values == [IssueFilter.unset] })

        var filter = urgent.toggled(in: IssueFilter(text: "login"))
        filter = noPriority.toggled(in: filter)
        filter = me.toggled(in: unassigned.toggled(in: filter))
        #expect(filter.priorities == [.urgent, .none])
        #expect(urgent.isOn(in: filter))

        let chips = FilterCatalog.chips(filter, snapshot: snapshot, userId: fixture.me.id)
        #expect(chips.map(\.dimension) == [.text, .priority, .assignee])
        #expect(chips.map(\.summary) == ["“login”", "Urgent, No priority", "No assignee, Me"])

        let open = IssueFilter(stateCategories: StateCategory.allCases.filter(\.isOpen))
        #expect(FilterCatalog.chips(open, snapshot: snapshot, userId: nil).map(\.summary) == ["Open"])
        #expect(FilterCatalog.chips(IssueFilter(stateCategories: [.started, .review]), snapshot: snapshot, userId: nil).first?.summary == "In Progress, In Review")
        #expect(FilterCatalog.clearing(.category, in: open).isEmpty)

        filter = urgent.toggled(in: filter)
        filter = noPriority.toggled(in: filter)
        #expect(filter.priorities == nil)
        #expect(FilterCatalog.clearing(.assignee, in: filter) == IssueFilter(text: "login"))
    }
}
