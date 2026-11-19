import Foundation
import MCP
import TrackaroCore

/// The Trackaro MCP server: tools, resources and prompts over any MCP transport.
public enum TrackaroMCPServer {
    public static let version = "0.3.0"

    public struct Options: Sendable {
        /// Hide every tool that writes. The server can still read everything.
        public var readOnly: Bool
        /// Overrides the agent name derived from the client, for example to tell two Claude sessions apart.
        public var agentName: String?
        /// Act as a Claude Code channel: push the user's changes into the session as they happen.
        public var channel: Bool
        /// How often channel mode checks for new changes.
        public var channelInterval: Duration
        /// The chat this server serves. `trackaro-mcp` passes Claude Code's `CLAUDE_CODE_SESSION_ID`; without one, each
        /// connection gets its own id. Locks are held by this id, and lock events addressed to it reach this chat only.
        public var sessionId: String?
        /// Recorded with locks so they are freed when this process ends. Nil leaves only the time to live.
        public var processId: Int?
        /// How often this server frees expired locks.
        public var lockSweepInterval: Duration

        public init(
            readOnly: Bool = false, agentName: String? = nil, channel: Bool = false, channelInterval: Duration = .milliseconds(700),
            sessionId: String? = nil, processId: Int? = nil, lockSweepInterval: Duration = .seconds(5)
        ) {
            self.readOnly = readOnly
            self.agentName = agentName
            self.channel = channel
            self.channelInterval = channelInterval
            self.sessionId = sessionId
            self.processId = processId
            self.lockSweepInterval = lockSweepInterval
        }
    }

    static var allTools: [ToolDefinition] {
        WorkspaceTools.all + IssueTools.all + ConversationTools.all + PlanningTools.all + ViewTools.all + ArtifactTools.all + LockTools.all
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
            instructions: Instructions.text(readOnly: options.readOnly, channel: options.channel),
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

        let channel = options.channel ? ChannelTransport(wrapping: transport) : nil
        try await server.start(transport: channel ?? transport) { client, _ in
            try await session.identify(client)
        }
        if let channel {
            startChannelPump(channel, store: store, session: session, interval: options.channelInterval)
            startLockPump(channel, store: store, sessionId: session.sessionId, interval: options.channelInterval)
        }
        if let processId = options.processId, options.sessionId != nil {
            try? store.adoptLocks(sessionId: session.sessionId, processId: processId)
        }
        if !options.readOnly { startLockSweep(store: store, interval: options.lockSweepInterval) }
        return server
    }

    /// Pushes lock events addressed to this chat, one event each: a lock it was waiting for is now its own, or a lock
    /// it held was taken away. Other chats' events are never read here.
    private static func startLockPump(_ channel: ChannelTransport, store: TrackaroStore, sessionId: String, interval: Duration) {
        Task {
            var cursor = (try? store.lockEventHead()) ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // A restore can bring back an older file whose events stop before the cursor.
                if let head = try? store.lockEventHead(), head < cursor { cursor = head }
                guard let events = try? store.lockEvents(after: cursor, for: sessionId) else { continue }
                for event in events {
                    cursor = max(cursor, event.id ?? cursor)
                    guard let message = LockTools.message(for: event, store: store) else { continue }
                    try? await channel.push(message.content, meta: message.meta)
                }
            }
        }
    }

    /// Frees locks whose holder stopped sending heartbeats or whose chat ended. Every server and the app run this,
    /// so expiry happens as long as anything Trackaro is running; the store makes concurrent sweeps safe.
    private static func startLockSweep(store: TrackaroStore, interval: Duration) {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                _ = try? store.expireLocks()
            }
        }
    }

    /// Checks the change feed and pushes what the user did into the session, batching everything since the
    /// last check into one event so a burst of edits costs Claude one turn, not one per field.
    private static func startChannelPump(_ channel: ChannelTransport, store: TrackaroStore, session: Session, interval: Duration) {
        Task {
            let feed = AgentFeed(store: store)
            var cursor = (try? store.feedHead()) ?? FeedCursor(activity: 0, comment: 0)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let agentId = await session.agentId
                guard let result = try? feed.changes(after: cursor, excludingMember: agentId) else { continue }
                cursor = result.cursor
                guard !result.lines.isEmpty, let message = AgentFeed.render(result.lines, as: .text) else { continue }
                let issues = Array(Set(result.events.map(\.issue.identifier))).sorted()
                var meta = ["source": "trackaro", "changes": "\(result.lines.count)", "issues": issues.joined(separator: ",")]
                if issues.count == 1 { meta["issue"] = issues[0] }
                try? await channel.push(message, meta: meta)
            }
        }
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
    nonisolated let sessionId: String
    private var agent: Member?

    init(store: TrackaroStore, user: Member, options: TrackaroMCPServer.Options) {
        self.store = store
        self.user = user
        self.options = options
        let given = options.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sessionId = given.isEmpty ? "mcp-\(UUID().uuidString.lowercased())" : given
    }

    func identify(_ client: Client.Info) throws {
        agent = try store.agent(named: options.agentName ?? TrackaroMCPServer.agentName(for: client), clientName: client.name)
    }

    var agentId: String? { agent?.id }

    func context() throws -> ToolContext {
        let current = try agent ?? store.agent(named: options.agentName ?? "Agent")
        agent = current
        return ToolContext(store: store, user: user, agent: current, sessionId: sessionId, processId: options.processId)
    }
}

enum Instructions {
    static func text(readOnly: Bool, channel: Bool = false) -> String {
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
                "Issue descriptions and comments show as GitHub-flavored Markdown in the app: headings, lists, task lists, tables, code blocks and links. Write the context the next person or agent will need, formatted so it can be scanned.",
                "Shared resources such as QA lanes and merge steps are locks: call acquire_lock before using one, heartbeat_lock during long runs, and release_lock with a result note when done. If the answer is queued, wait; this chat is told when the lock becomes its own. lock_status shows who holds what.",
                "Use save_artifact to keep anything longer-lived than a comment, such as a spec, plan, report, screenshot or HTML page, in its project. The user browses artifacts in the app; list_artifacts and get_artifact read them back.",
            ]
        }
        if channel {
            lines.append("Events from the trackaro channel are changes the user just made in the app, such as moving an issue to another column or commenting. Read them, then act with the Trackaro tools if they affect your work: start an issue moved into a started state, answer comments addressed to you, stop work on anything moved back or canceled. If nothing needs doing, say so briefly.")
        }
        return lines.joined(separator: "\n")
    }
}
