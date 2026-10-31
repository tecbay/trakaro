import Foundation
import TrackaroCore
import TrackaroKit

/// What the main list shows.
enum SidebarItem: Hashable {
    case myIssues
    case agentActivity
    case team(String, TeamPage)
    /// A saved view, by id.
    case view(String)

    enum TeamPage: String, CaseIterable, Hashable {
        case all, active, backlog

        var title: String {
            switch self {
            case .all: "Issues"
            case .active: "Active"
            case .backlog: "Backlog"
            }
        }

        var symbol: String {
            switch self {
            case .all: "square.stack"
            case .active: "circle.lefthalf.filled"
            case .backlog: "circle.dashed"
            }
        }

        var categories: [StateCategory]? {
            switch self {
            case .all: nil
            case .active: [.unstarted, .started, .review]
            case .backlog: [.triage, .backlog]
            }
        }
    }

    /// Stable across launches, for remembering per-view preferences.
    var storageKey: String {
        switch self {
        case .myIssues: "my-issues"
        case .agentActivity: "agent-activity"
        case let .team(id, page): "team.\(id).\(page.rawValue)"
        case let .view(id): "view.\(id)"
        }
    }

    var teamId: String? {
        if case let .team(id, _) = self { id } else { nil }
    }

    func title(in snapshot: WorkspaceSnapshot?) -> String {
        switch self {
        case .myIssues: "My issues"
        case .agentActivity: "Agent activity"
        case let .team(id, page):
            "\(snapshot?.teamsById[id]?.name ?? "Team") · \(page.title)"
        case let .view(id): snapshot?.savedViewsById[id]?.name ?? "View"
        }
    }

    var symbol: String {
        switch self {
        case .myIssues: "person.crop.circle"
        case .agentActivity: "sparkles"
        case let .team(_, page): page.symbol
        case .view: "line.3.horizontal.decrease.circle"
        }
    }

    var emptyMessage: String {
        switch self {
        case .myIssues: "Nothing assigned to you. Press C to create an issue."
        case .agentActivity: "No agent has changed anything yet. Connect Claude Code or Cursor with trackaro-mcp."
        case .team(_, .backlog): "The backlog is empty."
        case .team(_, .active): "Nothing in progress."
        case .team: "No issues yet. Press C to create one."
        case .view: "No issues match this view."
        }
    }
}
