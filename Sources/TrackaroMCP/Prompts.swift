import Foundation
import MCP
import TrackaroCore

/// Ready-made workflows. Each prompt carries the current data inline, so the agent starts with facts, not a lookup.
enum Prompts {
    static func list(readOnly: Bool) -> [Prompt] {
        var prompts = [
            Prompt(
                name: "standup",
                title: "Standup",
                description: "Summarise what moved recently, what is in progress and what is blocked.",
                arguments: [.init(name: "hours", description: "Look-back window in hours. Default 24.", required: false)]
            ),
        ]
        if !readOnly {
            prompts += [
                Prompt(
                    name: "triage",
                    title: "Triage",
                    description: "Review untriaged and unprioritised issues and propose priority, labels and state.",
                    arguments: [.init(name: "team", description: "Team key. Default all teams.", required: false)]
                ),
                Prompt(
                    name: "plan_work",
                    title: "Plan work",
                    description: "Break a goal into a parent issue with ordered, estimated sub-issues.",
                    arguments: [
                        .init(name: "goal", description: "What should be achieved.", required: true),
                        .init(name: "team", description: "Team key. Default the only team.", required: false),
                    ]
                ),
            ]
        }
        return prompts
    }

    static func get(_ name: String, arguments: [String: String], context: ToolContext) throws -> GetPrompt.Result {
        do {
            switch name {
            case "standup": return try standup(arguments, context: context)
            case "triage": return try triage(arguments, context: context)
            case "plan_work": return try planWork(arguments, context: context)
            default: throw MCPError.invalidParams("Unknown prompt \(name). Available: standup, triage, plan_work.")
            }
        } catch let error as TrackaroError {
            throw MCPError.invalidParams(error.description)
        }
    }

    private static func standup(_ arguments: [String: String], context: ToolContext) throws -> GetPrompt.Result {
        let hours = Int(arguments["hours"] ?? "") ?? 24
        let cutoff = context.store.now().addingTimeInterval(-Double(max(hours, 1)) * 3600)
        let recent = try context.store.queryIssues(IssueQuery(order: .updated, limit: 100)).issues.filter { $0.updatedAt >= cutoff }
        let inProgress = try context.store.queryIssues(IssueQuery(stateCategories: [.started, .review], limit: 100)).issues
        let presenter = Presenter(store: context.store, snapshot: try context.store.snapshot())
        let text = """
            Write a short standup from my Trackaro issues. Use four headings: Done, In progress, Blocked, Next. \
            One line per issue, starting with its identifier. Call get_issue_history or list_comments only where the \
            reason for a change is unclear.

            Issues updated in the last \(hours) hours:
            \(Output.render(.array(try presenter.summaries(recent))))

            Issues currently started or in review:
            \(Output.render(.array(try presenter.summaries(inProgress))))
            """
        return GetPrompt.Result(description: "Standup for the last \(hours) hours", messages: [.user(.text(text: text))])
    }

    private static func triage(_ arguments: [String: String], context: ToolContext) throws -> GetPrompt.Result {
        let resolver = try Resolver(context)
        var query = IssueQuery(stateCategories: [.triage, .backlog], order: .created, limit: 50)
        if let team = arguments["team"], !team.isEmpty { query.teamIds = [try resolver.team(team).id] }
        let candidates = try context.store.queryIssues(query).issues.filter {
            resolver.snapshot.statesById[$0.stateId]?.category == .triage || $0.priority == .none
        }
        let presenter = Presenter(store: context.store, snapshot: resolver.snapshot)
        let text = """
            Help me triage these Trackaro issues. For each one, propose a priority, labels from the existing set, \
            and a state (keep in Backlog, move to Todo, or close with mark_duplicate if it repeats another issue). \
            Show the plan as a table and wait for my approval. Then apply it with bulk_update_issues where issues \
            share a change, and update_issue or mark_duplicate otherwise.

            Labels: \(resolver.snapshot.labels.map(\.name).joined(separator: ", "))

            Issues to triage:
            \(Output.render(.array(try presenter.summaries(candidates))))
            """
        return GetPrompt.Result(description: "Triage \(candidates.count) issues", messages: [.user(.text(text: text))])
    }

    private static func planWork(_ arguments: [String: String], context: ToolContext) throws -> GetPrompt.Result {
        guard let goal = arguments["goal"]?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else {
            throw MCPError.invalidParams("plan_work needs a goal.")
        }
        let resolver = try Resolver(context)
        let team = try resolver.team(arguments["team"].flatMap { $0.isEmpty ? nil : $0 })
        let states = resolver.snapshot.states(ofTeam: team.id).map(\.name).joined(separator: ", ")
        let text = """
            Plan this work in Trackaro, team \(team.key).

            Goal: \(goal)

            First propose a breakdown: one parent issue and its sub-issues, each with a title, a one-paragraph \
            description, an estimate in points, and dependencies between them. Read the codebase first if the goal \
            is about code. Wait for my approval. Then create the parent with create_issue, the children with one \
            create_sub_issues call, and record dependencies with set_relation type blocks.

            States in \(team.key): \(states)
            Labels: \(resolver.snapshot.labels.filter { $0.teamId == nil || $0.teamId == team.id }.map(\.name).joined(separator: ", "))
            """
        return GetPrompt.Result(description: "Plan: \(goal)", messages: [.user(.text(text: text))])
    }
}
