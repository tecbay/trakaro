import Foundation
import TrackaroCore

/// Turns the names an agent naturally uses into stored ids. Every miss lists what would have matched,
/// so the agent can correct itself in one step instead of calling a listing tool.
struct Resolver {
    let context: ToolContext
    let snapshot: WorkspaceSnapshot

    init(_ context: ToolContext) throws {
        self.context = context
        snapshot = try context.store.snapshot()
    }

    var activeTeams: [Team] { snapshot.teams.filter { $0.archivedAt == nil } }

    /// A team by key, name or id. With no reference, the only team, if there is just one.
    func team(_ reference: String?) throws -> Team {
        guard let reference else {
            if activeTeams.count == 1, let only = activeTeams.first { return only }
            throw TrackaroError.invalid(field: "team", message: "Required when there are several teams. Teams: \(activeTeams.map(\.key).joined(separator: ", ")).")
        }
        if let byId = snapshot.teamsById[reference] { return byId }
        let matches = activeTeams.filter { same($0.key, reference) || same($0.name, reference) }
        if let only = matches.first, matches.count == 1 { return only }
        throw TrackaroError.noMatch(entity: "team", reference: reference, options: activeTeams.map(\.key))
    }

    /// A state of one team, by name or id. A category name works when the team has exactly one state in it.
    func state(_ reference: String, in team: Team) throws -> WorkflowState {
        let states = snapshot.states(ofTeam: team.id)
        if let byId = states.first(where: { $0.id == reference }) { return byId }
        if let byName = states.first(where: { same($0.name, reference) }) { return byName }
        if let category = StateCategory(rawValue: reference.lowercased()) {
            let inCategory = states.filter { $0.category == category }
            if let only = inCategory.first, inCategory.count == 1 { return only }
        }
        throw TrackaroError.noMatch(entity: "state in \(team.key)", reference: reference, options: states.map(\.name))
    }

    /// State ids across teams sharing a name, for filters like "everything In Progress".
    func stateIds(named reference: String, teams: [Team]) throws -> [String] {
        let teamIds = Set(teams.map(\.id))
        let states = snapshot.states.filter { teamIds.contains($0.teamId) }
        let matches = states.filter { same($0.name, reference) || $0.id == reference }
        guard !matches.isEmpty else {
            throw TrackaroError.noMatch(entity: "state", reference: reference, options: Array(Set(states.map(\.name))).sorted())
        }
        return matches.map(\.id)
    }

    /// Labels usable on a team's issues, by name or id.
    func labels(_ references: [String], for team: Team) throws -> [IssueLabel] {
        let available = snapshot.labels.filter { $0.teamId == nil || $0.teamId == team.id }
        return try references.map { reference in
            if let match = available.first(where: { $0.id == reference || same($0.name, reference) }) { return match }
            throw TrackaroError.noMatch(entity: "label for \(team.key)", reference: reference, options: available.map(\.name))
        }
    }

    /// Labels by name across every team, for filters.
    func labelIds(named reference: String) throws -> [String] {
        let matches = snapshot.labels.filter { $0.id == reference || same($0.name, reference) }
        guard !matches.isEmpty else {
            throw TrackaroError.noMatch(entity: "label", reference: reference, options: snapshot.labels.map(\.name))
        }
        return matches.map(\.id)
    }

    /// "me" is the user, "self" is the calling agent; otherwise a member by name or id.
    func member(_ reference: String) throws -> Member {
        switch reference.lowercased() {
        case "me", "user": return context.user
        case "self", "agent", "you": return context.agent
        default: break
        }
        if let byId = snapshot.membersById[reference] { return byId }
        let matches = snapshot.members.filter { same($0.name, reference) }
        if let only = matches.first, matches.count == 1 { return only }
        throw TrackaroError.noMatch(entity: "member", reference: reference, options: ["me", "self"] + snapshot.members.map(\.name))
    }

    func project(_ reference: String) throws -> Project {
        let active = snapshot.projects.filter { $0.archivedAt == nil }
        if let byId = snapshot.projectsById[reference] { return byId }
        let matches = active.filter { same($0.slug, reference) || same($0.name, reference) }
        if let only = matches.first, matches.count == 1 { return only }
        throw TrackaroError.noMatch(entity: "project", reference: reference, options: active.map(\.name))
    }

    /// A milestone by id or name. The name is looked up in `project` when given, otherwise across all projects.
    func milestone(_ reference: String, project: Project?) throws -> Milestone {
        if let byId = snapshot.milestonesById[reference] { return byId }
        let pool = snapshot.milestones.filter { project == nil || $0.projectId == project?.id }
        let matches = pool.filter { same($0.name, reference) }
        if let only = matches.first, matches.count == 1 { return only }
        if matches.count > 1 {
            throw TrackaroError.conflict(
                message: "\"\(reference)\" names milestones in several projects. Pass the project too.",
                candidates: matches.compactMap { snapshot.projectsById[$0.projectId]?.name }
            )
        }
        throw TrackaroError.noMatch(entity: "milestone", reference: reference, options: pool.map(\.name))
    }

    /// "active", a cycle number, or an id, within one team.
    func cycle(_ reference: String, in team: Team) throws -> Cycle {
        let cycles = snapshot.cycles.filter { $0.teamId == team.id }
        if reference.lowercased() == "active" {
            guard let active = try context.store.activeCycle(teamId: team.id) else {
                throw TrackaroError.notFound(entity: "active cycle in \(team.key)", reference: "active")
            }
            return active
        }
        if let byId = cycles.first(where: { $0.id == reference }) { return byId }
        let digits = reference.hasPrefix("#") ? String(reference.dropFirst()) : reference
        if let number = Int(digits), let byNumber = cycles.first(where: { $0.number == number }) { return byNumber }
        if let byName = cycles.first(where: { $0.name.map { same($0, reference) } ?? false }) { return byName }
        throw TrackaroError.noMatch(entity: "cycle in \(team.key)", reference: reference, options: ["active"] + cycles.map { String($0.number) })
    }

    func issue(_ reference: String) throws -> Issue {
        try context.store.issue(reference)
    }

    private func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
