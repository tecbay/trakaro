import Foundation
import MCP
import TrackaroCore

/// Read-only views an agent or client can attach as context without calling a tool.
enum Resources {
    static let workspaceURI = "trackaro://workspace"
    static let activeCyclesURI = "trackaro://cycles/active"
    static let issuePrefix = "trackaro://issue/"

    static var list: [Resource] {
        [
            Resource(name: "workspace", uri: workspaceURI, title: "Workspace",
                     description: "Teams, workflow states, labels, projects, members and active cycles.", mimeType: "application/json"),
            Resource(name: "active-cycles", uri: activeCyclesURI, title: "Active cycles",
                     description: "Progress of every team's running cycle.", mimeType: "application/json"),
        ]
    }

    static var templates: [Resource.Template] {
        [
            Resource.Template(uriTemplate: "\(issuePrefix){identifier}", name: "issue", title: "Issue",
                              description: "Full details of one issue, such as trackaro://issue/ENG-42.", mimeType: "application/json"),
        ]
    }

    static func read(_ uri: String, context: ToolContext) throws -> ReadResource.Result {
        let value: Value
        do {
            if uri == workspaceURI {
                value = try WorkspaceTools.workspace(context)
            } else if uri == activeCyclesURI {
                value = try activeCycles(context)
            } else if uri.hasPrefix(issuePrefix) {
                let reference = String(uri.dropFirst(issuePrefix.count)).removingPercentEncoding ?? ""
                let issue = try context.store.issue(reference)
                value = try Presenter(store: context.store, snapshot: context.store.snapshot()).detail(issue)
            } else {
                throw MCPError.invalidParams("Unknown resource \(uri). Try \(workspaceURI), \(activeCyclesURI) or \(issuePrefix)ENG-1.")
            }
        } catch let error as TrackaroError {
            throw MCPError.invalidParams(error.description)
        }
        return ReadResource.Result(contents: [.text(Output.render(value), uri: uri, mimeType: "application/json")])
    }

    private static func activeCycles(_ context: ToolContext) throws -> Value {
        let snapshot = try context.store.snapshot()
        let presenter = Presenter(store: context.store, snapshot: snapshot)
        let now = context.store.now()
        let progress: [Value] = try snapshot.teams.filter { $0.archivedAt == nil }.compactMap { team in
            guard let cycle = try context.store.activeCycle(teamId: team.id) else { return nil }
            return presenter.progress(try context.store.cycleProgress(cycleId: cycle.id), now: now)
        }
        return ["cycles": .array(progress)]
    }
}
