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
    case projects
    case project(String)
    /// Artifacts of one project, or of every project when nil.
    case artifacts(String?)
    /// A team's cycles, by team id.
    case cycles(String)
    case cycle(String)

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
        case .projects: "projects"
        case let .project(id): "project.\(id)"
        case let .artifacts(id): "artifacts.\(id ?? "all")"
        case let .cycles(teamId): "cycles.\(teamId)"
        case let .cycle(id): "cycle.\(id)"
        }
    }

    var teamId: String? {
        switch self {
        case let .team(id, _), let .cycles(id): id
        default: nil
        }
    }

    var isArtifacts: Bool {
        if case .artifacts = self { true } else { false }
    }

    /// Pages that show cards of projects or cycles rather than a list of issues.
    var isOverview: Bool {
        switch self {
        case .projects, .cycles, .artifacts: true
        default: false
        }
    }

    func title(in snapshot: WorkspaceSnapshot?) -> String {
        switch self {
        case .myIssues: "My issues"
        case .agentActivity: "Agent activity"
        case let .team(id, page):
            "\(snapshot?.teamsById[id]?.name ?? "Team") · \(page.title)"
        case let .view(id): snapshot?.savedViewsById[id]?.name ?? "View"
        case .projects: "Projects"
        case let .project(id): snapshot?.projectsById[id]?.name ?? "Project"
        case .artifacts(nil): "Artifacts"
        case let .artifacts(id?): "\(snapshot?.projectsById[id]?.name ?? "Project") · Artifacts"
        case let .cycles(teamId): "\(snapshot?.teamsById[teamId]?.name ?? "Team") · Cycles"
        case let .cycle(id): snapshot?.cyclesById[id].map(CycleTiming.title) ?? "Cycle"
        }
    }

    var symbol: String {
        switch self {
        case .myIssues: "person.crop.circle"
        case .agentActivity: "sparkles"
        case let .team(_, page): page.symbol
        case .view: "line.3.horizontal.decrease.circle"
        case .projects: "cube.box"
        case .project: "cube"
        case .artifacts: "doc.richtext"
        case .cycles: "arrow.triangle.2.circlepath"
        case .cycle: "arrow.triangle.2.circlepath.circle"
        }
    }

    var emptyMessage: String {
        switch self {
        case .myIssues: "Nothing assigned to you. Press C to create an issue."
        case .agentActivity: "No agent has changed anything yet. Use Connect an agent in the sidebar to get started."
        case .team(_, .backlog): "The backlog is empty."
        case .team(_, .active): "Nothing in progress."
        case .team: "No issues yet. Press C to create one."
        case .view: "No issues match this view."
        case .projects: "No projects yet."
        case .project: "No issues in this project yet. Press C to create one."
        case .artifacts: "No artifacts yet. Ask your agent to save a spec, report or file to a project."
        case .cycles: "No cycles yet."
        case .cycle: "No issues in this cycle yet. Press C to create one, or set Cycle in an issue's details."
        }
    }
}
