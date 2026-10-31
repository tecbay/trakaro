import Foundation
import MCP
import TrackaroCore

/// Orientation and setup.
enum WorkspaceTools {
    static var all: [ToolDefinition] {
        [getWorkspace, createLabel, createTeam]
    }

    static let getWorkspace = ToolDefinition(
        name: "get_workspace",
        title: "Get workspace",
        description: """
            Start here. Teams with their keys and workflow states, labels, projects, active cycles, members and \
            saved views, in one call. Use these exact names in other tools.
            """,
        inputSchema: JSONSchema.object([:]),
        readOnly: true
    ) { context, _ in
        try workspace(context)
    }

    /// Shared with the `trackaro://workspace` resource.
    static func workspace(_ context: ToolContext) throws -> Value {
        let snapshot = try context.store.snapshot()
        let presenter = Presenter(store: context.store, snapshot: snapshot)
        let now = context.store.now()
        let teams: [Value] = try snapshot.teams.filter { $0.archivedAt == nil }.map { team in
            var object = ObjectBuilder()
            object.set("key", team.key)
            object.set("name", team.name)
            object.set("states", .array(snapshot.states(ofTeam: team.id).map {
                ["name": .string($0.name), "category": .string($0.category.rawValue)]
            }))
            if let active = try context.store.activeCycle(teamId: team.id) {
                object.set("active_cycle", presenter.cycle(active, now: now))
            }
            return object.value
        }
        let labels: [Value] = snapshot.labels.map { label in
            var object = ObjectBuilder()
            object.set("name", label.name)
            object.set("team", label.teamId.flatMap { snapshot.teamsById[$0]?.key })
            return object.value
        }
        let members: [Value] = snapshot.members.map { member in
            var object = ObjectBuilder()
            object.set("name", member.name)
            object.set("kind", member.kind.rawValue)
            if member.id == context.user.id { object.set("is", "me") }
            if member.id == context.agent.id { object.set("is", "self") }
            return object.value
        }
        var result = ObjectBuilder()
        result.set("you", context.agent.name)
        result.set("user", context.user.name)
        result.set("teams", .array(teams))
        result.set("labels", .array(labels))
        result.set("projects", .array(snapshot.projects.filter { $0.archivedAt == nil }.map { .string($0.name) }))
        result.set("members", .array(members))
        result.set("views", .array(snapshot.savedViews.map { ViewTools.describe($0, snapshot: snapshot).value }))
        result.set("priorities", .array(Priority.allCases.map { .string($0.name) }))
        return result.value
    }

    static let createLabel = ToolDefinition(
        name: "create_label",
        title: "Create label",
        description: "Create a label. Without team it is available to every team.",
        inputSchema: JSONSchema.object([
            "name": JSONSchema.string("Label name, unique within its scope."),
            "color": JSONSchema.string("Hex color such as #5E6AD2. Default grey."),
            "team": JSONSchema.string("Team key or name to scope the label to one team."),
        ], required: ["name"]),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let team = try arguments.string("team").map { try resolver.team($0) }
        let color = try arguments.string("color") ?? "#95A2B3"
        guard color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
            throw TrackaroError.invalid(field: "color", message: "Use a hex color such as #5E6AD2.")
        }
        let label = try context.store.createLabel(name: try arguments.requiredString("name"), color: color, teamId: team?.id, by: context.agent.id)
        var result = ObjectBuilder()
        result.set("name", label.name)
        result.set("color", label.color)
        result.set("team", team?.key)
        return result.value
    }

    static let createTeam = ToolDefinition(
        name: "create_team",
        title: "Create team",
        description: "Create a team with the default workflow. Its key prefixes issue identifiers, like ENG in ENG-42.",
        inputSchema: JSONSchema.object([
            "key": JSONSchema.string("2 to 6 letters or digits, starting with a letter."),
            "name": JSONSchema.string("Team name."),
        ], required: ["key", "name"]),
        readOnly: false
    ) { context, arguments in
        let team = try context.store.createTeam(key: try arguments.requiredString("key"), name: try arguments.requiredString("name"), by: context.agent.id)
        let states = try context.store.states(teamId: team.id)
        return [
            "key": .string(team.key),
            "name": .string(team.name),
            "states": .array(states.map { ["name": .string($0.name), "category": .string($0.category.rawValue)] }),
        ]
    }
}
