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
            guard let team = snapshot?.teams.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame && $0.archivedAt == nil }) else {
                showToast("No team with key \(key)", isError: true)
                return
            }
            sidebarSelection = .team(team.id, page.flatMap(SidebarItem.TeamPage.init(rawValue:)) ?? .all)
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
}
