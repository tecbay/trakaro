import Foundation
import TrackaroCore
import TrackaroKit

extension AppModel {
    /// Handles a `trackaro://` link. Unknown links show a toast instead of failing silently.
    func open(_ url: URL) {
        guard let link = AppLink(url: url) else {
            showToast("Trackaro cannot open \(url.absoluteString)", isError: true)
            return
        }
        overlay = nil
        switch link {
        case let .issue(reference):
            guard let store, let issue = try? store.issue(reference) else {
                showToast("No issue matches \(reference)", isError: true)
                return
            }
            focus(issue.id)
        case .myIssues:
            sidebarSelection = .myIssues
        case .agentActivity:
            sidebarSelection = .agentActivity
        case let .team(key, page):
            guard let team = team(withKey: key) else { return }
            sidebarSelection = .team(team.id, page.flatMap(SidebarItem.TeamPage.init(rawValue:)) ?? .all)
        case .projects:
            sidebarSelection = .projects
        case let .project(reference):
            let wanted = reference.lowercased()
            guard let project = snapshot?.projects.first(where: { $0.id == reference || $0.slug == wanted || $0.name.lowercased() == wanted }) else {
                showToast("No project matches \(reference)", isError: true)
                return
            }
            sidebarSelection = .project(project.id)
        case let .cycles(key):
            guard let team = team(withKey: key) else { return }
            sidebarSelection = .cycles(team.id)
        case let .cycle(key, reference):
            guard let team = team(withKey: key) else { return }
            let cycle = reference == "current"
                ? currentCycle(teamId: team.id)
                : snapshot?.cycles.first { $0.teamId == team.id && ("\($0.number)" == reference || $0.id == reference) }
            guard let cycle else {
                showToast("No cycle \(reference) in \(team.key)", isError: true)
                return
            }
            sidebarSelection = .cycle(cycle.id)
        case let .view(reference):
            guard let view = snapshot?.savedViews.first(where: { $0.id == reference || $0.name.caseInsensitiveCompare(reference) == .orderedSame }) else {
                showToast("No view named \(reference)", isError: true)
                return
            }
            sidebarSelection = .view(view.id)
        case let .command(command):
            if canPerform(command) { perform(command) }
        }
    }

    private func team(withKey key: String) -> Team? {
        guard let team = snapshot?.teams.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame && $0.archivedAt == nil }) else {
            showToast("No team with key \(key)", isError: true)
            return nil
        }
        return team
    }
}
