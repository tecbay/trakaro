import Foundation
import TrackaroCore
import TrackaroKit

/// Projects and cycles: creating them, updating a project, and completing a cycle.
extension AppModel {
    var openCycle: Cycle? {
        guard case let .cycle(id) = currentItem else { return nil }
        return snapshot?.cyclesById[id]
    }

    var openProject: Project? {
        guard case let .project(id) = currentItem else { return nil }
        return snapshot?.projectsById[id]
    }

    /// A new issue created on a project or cycle page belongs to it.
    var defaultProjectId: String? { openProject?.id }
    var defaultCycleId: String? { openCycle?.id }

    /// The cycle running now for a team: the one the sidebar's "Current cycle" opens.
    func currentCycle(teamId: String) -> Cycle? {
        guard let snapshot, let store else { return nil }
        let now = store.now()
        return snapshot.cycles.first { $0.teamId == teamId && CycleTiming.phase($0, now: now) == .current }
    }

    func goToCurrentCycle() {
        guard let teamId = defaultTeamId else { return }
        sidebarSelection = currentCycle(teamId: teamId).map { .cycle($0.id) } ?? .cycles(teamId)
    }

    // MARK: Projects

    func createProject(name: String, summary: String, status: ProjectStatus, targetDate: CalendarDate?) -> Bool {
        guard let store, let user else { return false }
        do {
            let project = try store.createProject(name: name, summary: summary, status: status, targetDate: targetDate, by: user.id)
            reloadAll()
            sidebarSelection = .project(project.id)
            showToast("Created project “\(project.name)”")
            return true
        } catch {
            showError(error)
            return false
        }
    }

    func updateProject(_ id: String, _ patch: ProjectPatch) {
        guard let store, let user else { return }
        do {
            try store.updateProject(id, patch, by: user.id)
            reloadAll()
        } catch {
            showError(error)
        }
    }

    func createMilestone(named name: String, in projectId: String) {
        guard let store, let user, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try store.createMilestone(projectId: projectId, name: name, by: user.id)
            reloadAll()
        } catch {
            showError(error)
        }
    }

    // MARK: Cycles

    /// Adds the team's next cycle: a week long, starting when the last one ends, or now.
    func createCycle() {
        guard let store, let user, let teamId = defaultTeamId else { return }
        do {
            let cycle = try store.createCycle(teamId: teamId, by: user.id)
            reloadAll()
            showToast("Created \(CycleTiming.title(cycle)), \(CycleTiming.range(cycle))")
        } catch {
            showError(error)
        }
    }

    /// Completes straight away when nothing is unfinished; otherwise asks what to do with the unfinished issues.
    func requestCompleteCycle(_ cycle: Cycle) {
        if unfinishedIssueIds(in: cycle.id).isEmpty {
            completeCycle(cycle, moveUnfinished: false)
        } else {
            cycleToComplete = cycle
        }
    }

    /// Completes a cycle. With `moveUnfinished`, its open issues move to the next cycle first, creating it when the
    /// team has none yet. The move is one undo step.
    func completeCycle(_ cycle: Cycle, moveUnfinished: Bool) {
        guard let store, let user else { return }
        cycleToComplete = nil
        do {
            var destination: Cycle?
            if moveUnfinished {
                let next = try store.nextCycle(after: cycle) ?? store.createCycle(teamId: cycle.teamId, by: user.id)
                let ids = unfinishedIssueIds(in: cycle.id)
                setCycle(next.id, on: ids)
                destination = next
            }
            try store.completeCycle(cycle.id, by: user.id)
            reloadAll()
            if let destination {
                showToast("Completed \(CycleTiming.title(cycle)). Unfinished issues moved to \(CycleTiming.title(destination)).")
            } else {
                showToast("Completed \(CycleTiming.title(cycle))")
            }
        } catch {
            showError(error)
        }
    }

    func unfinishedIssueIds(in cycleId: String) -> [String] {
        guard let store else { return [] }
        let open = StateCategory.allCases.filter(\.isOpen)
        return (try? store.queryIssues(IssueQuery(stateCategories: open, cycle: .anyOf([cycleId]), limit: TrackaroStore.maxPageSize)).issues.map(\.id)) ?? []
    }
}
