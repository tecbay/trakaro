import Foundation
import MCP
import TrackaroCore

/// The Trackaro MCP server: tools, resources and prompts over any MCP transport.
public enum TrackaroMCPServer {
    public static let version = "0.1.0"

    public struct Options: Sendable {
        /// Hide every tool that writes. The server can still read everything.
        public var readOnly: Bool
        /// Overrides the agent name derived from the client, for example to tell two Claude sessions apart.
        public var agentName: String?

        public init(readOnly: Bool = false, agentName: String? = nil) {
            self.readOnly = readOnly
            self.agentName = agentName
        }
    }

    static var allTools: [ToolDefinition] {
        WorkspaceTools.all + IssueTools.all + ConversationTools.all + PlanningTools.all
    }

    static func tools(for options: Options) -> [ToolDefinition] {
        options.readOnly ? allTools.filter(\.readOnly) : allTools
    }

    /// Builds the server, connects it to `transport` and starts handling messages. Returns once the transport is
    /// connected; call `waitUntilCompleted()` on the result to block until the client disconnects.
    @discardableResult
    public static func start(store: TrackaroStore, options: Options = Options(), transport: any Transport) async throws -> Server {
        let session = Session(store: store, user: try store.localUser(), options: options)
        let tools = tools(for: options)
        let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        let server = Server(
            name: "trackaro",
            version: version,
            title: "Trackaro",
            instructions: Instructions.text(readOnly: options.readOnly),
            capabilities: .init(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard let definition = toolsByName[params.name] else {
                let available = tools.map(\.name).joined(separator: ", ")
                let hint = options.readOnly && allTools.contains(where: { $0.name == params.name })
                    ? "\(params.name) writes data and this server is read-only."
                    : "Unknown tool \(params.name). Available: \(available)."
                return CallTool.Result(content: [Output.text("Error: \(hint)")], isError: true)
            }
            return definition.call(try await session.context(), params.arguments)
        }

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: Resources.list)
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: Resources.templates)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            try Resources.read(params.uri, context: try await session.context())
        }

        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: Prompts.list(readOnly: options.readOnly))
        }
        await server.withMethodHandler(GetPrompt.self) { params in
            try Prompts.get(params.name, arguments: params.arguments ?? [:], context: try await session.context())
        }

        try await server.start(transport: transport) { client, _ in
            try await session.identify(client)
        }
        return server
    }

    /// The name the agent appears under in Trackaro's history, from what the client reports about itself.
    static func agentName(for client: Client.Info) -> String {
        if let title = client.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty { return title }
        let name = client.name.lowercased()
        if name == "claude-code" { return "Claude Code" }
        if name.hasPrefix("claude") { return "Claude" }
        if name.hasPrefix("cursor") { return "Cursor" }
        let words = client.name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        let pretty = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return pretty.isEmpty ? "Agent" : pretty
    }
}

/// Per-connection state: who the agent is. Resolved from the client's initialize request.
actor Session {
    let store: TrackaroStore
    let user: Member
    let options: TrackaroMCPServer.Options
    private var agent: Member?

    init(store: TrackaroStore, user: Member, options: TrackaroMCPServer.Options) {
        self.store = store
        self.user = user
        self.options = options
    }

    func identify(_ client: Client.Info) throws {
        agent = try store.agent(named: options.agentName ?? TrackaroMCPServer.agentName(for: client), clientName: client.name)
    }

    func context() throws -> ToolContext {
        let current = try agent ?? store.agent(named: options.agentName ?? "Agent")
        agent = current
        return ToolContext(store: store, user: user, agent: current)
    }
}

enum Instructions {
    static func text(readOnly: Bool) -> String {
        var lines = [
            "Trackaro is the user's local task tracker on this Mac. Issues have identifiers like ENG-42 (team key and number).",
            "Call get_workspace first: it lists teams, workflow state names, labels and projects. Use those exact names.",
            "In arguments, \"me\" is the user and \"self\" is you. Everything you change is recorded under your name in the issue's history, and the user sees it live in the app.",
        ]
        if readOnly {
            lines.append("This connection is read-only: you can search and read, but not change anything.")
        } else {
            lines += [
                "To change status, set state with update_issue, or use move_issue to also reorder or change team. Omitted fields stay as they are; null clears a field.",
                "When you start an issue, move it to a started state such as In Progress. When you finish, add_comment with what you did and how you verified it, then move it to a review or completed state.",
                "Prefer search_issues (compact) to find work and get_issues for full detail. Batch with create_sub_issues and bulk_update_issues instead of many single calls.",
            ]
        }
        return lines.joined(separator: "\n")
    }
}
