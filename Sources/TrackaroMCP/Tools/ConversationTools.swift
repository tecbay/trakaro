import Foundation
import MCP
import TrackaroCore

/// Comments, history and links between issues.
enum ConversationTools {
    static var all: [ToolDefinition] {
        [addComment, listComments, getIssueHistory, setRelation, removeRelation, markDuplicate]
    }

    static let addComment = ToolDefinition(
        name: "add_comment",
        title: "Add comment",
        description: """
            Comment on an issue in markdown. Good practice: when you finish work on an issue, comment with what you \
            changed and how you verified it before moving it to review or done.
            """,
        inputSchema: JSONSchema.object([
            "issue": IssueTools.issueRef,
            "body": JSONSchema.string("Markdown text."),
            "reply_to": JSONSchema.string("Id of the comment this replies to."),
        ], required: ["issue", "body"]),
        readOnly: false
    ) { context, arguments in
        let comment = try context.store.addComment(
            to: try arguments.requiredString("issue"),
            body: try arguments.text("body") ?? "",
            replyingTo: try arguments.string("reply_to"),
            by: context.agent.id
        )
        return Presenter(store: context.store, snapshot: try context.store.snapshot()).comment(comment)
    }

    static let listComments = ToolDefinition(
        name: "list_comments",
        title: "List comments",
        description: "An issue's comments, oldest first. Read them before replying or picking up someone else's work.",
        inputSchema: JSONSchema.object(["issue": IssueTools.issueRef], required: ["issue"]),
        readOnly: true
    ) { context, arguments in
        let reference = try arguments.requiredString("issue")
        let issue = try context.store.issue(reference)
        let presenter = Presenter(store: context.store, snapshot: try context.store.snapshot())
        let comments = try context.store.comments(on: issue.id).map(presenter.comment)
        return ["issue": .string(issue.identifier), "comments": .array(comments)]
    }

    static let getIssueHistory = ToolDefinition(
        name: "get_issue_history",
        title: "Get issue history",
        description: "Who changed what on an issue and when, newest last. Values are shown by name.",
        inputSchema: JSONSchema.object([
            "issue": IssueTools.issueRef,
            "limit": JSONSchema.integer("Most recent entries to return, 1 to 200. Default 50.", minimum: 1, maximum: 200),
        ], required: ["issue"]),
        readOnly: true
    ) { context, arguments in
        let issue = try context.store.issue(try arguments.requiredString("issue"))
        let limit = min(max(try arguments.int("limit") ?? 50, 1), 200)
        let presenter = Presenter(store: context.store, snapshot: try context.store.snapshot())
        let entries = try context.store.activity(issueId: issue.id).suffix(limit).map(presenter.activity)
        return ["issue": .string(issue.identifier), "history": .array(entries)]
    }

    static let relationTypes = RelationType.allCases.map(\.rawValue)

    static let setRelation = ToolDefinition(
        name: "set_relation",
        title: "Link issues",
        description: """
            Link two issues. The inverse link is recorded too: ENG-1 blocks ENG-2 also makes ENG-2 blocked_by ENG-1. \
            An issue with an open blocker shows blocked: true in get_issues.
            """,
        inputSchema: JSONSchema.object([
            "issue": IssueTools.issueRef,
            "type": JSONSchema.string("How issue relates to related.", oneOf: relationTypes),
            "related": JSONSchema.string("The other issue."),
        ], required: ["issue", "type", "related"]),
        readOnly: false
    ) { context, arguments in
        let (issue, type, related) = try relationArguments(arguments)
        try context.store.setRelation(type, from: issue, to: related, by: context.agent.id)
        return try relations(of: issue, context: context)
    }

    static let removeRelation = ToolDefinition(
        name: "remove_relation",
        title: "Unlink issues",
        description: "Remove a link between two issues, and its inverse.",
        inputSchema: JSONSchema.object([
            "issue": IssueTools.issueRef,
            "type": JSONSchema.string("The relation to remove.", oneOf: relationTypes),
            "related": JSONSchema.string("The other issue."),
        ], required: ["issue", "type", "related"]),
        readOnly: false,
        destructive: true
    ) { context, arguments in
        let (issue, type, related) = try relationArguments(arguments)
        try context.store.removeRelation(type, from: issue, to: related, by: context.agent.id)
        return try relations(of: issue, context: context)
    }

    static let markDuplicate = ToolDefinition(
        name: "mark_duplicate",
        title: "Mark duplicate",
        description: """
            Close an issue as a duplicate of another: links it with duplicate_of and moves it to the team's \
            Duplicate state (or its first canceled state). The original stays open.
            """,
        inputSchema: JSONSchema.object([
            "issue": JSONSchema.string("The duplicate to close."),
            "duplicate_of": JSONSchema.string("The issue to keep."),
        ], required: ["issue", "duplicate_of"]),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let duplicate = try resolver.issue(try arguments.requiredString("issue"))
        let original = try resolver.issue(try arguments.requiredString("duplicate_of"))
        let states = resolver.snapshot.states(ofTeam: duplicate.teamId)
        guard let closed = states.first(where: { $0.name.lowercased() == "duplicate" }) ?? states.first(where: { $0.category == .canceled }) else {
            throw TrackaroError.invalid(field: "issue", message: "The team has no canceled state to close the duplicate into.")
        }
        try context.store.setRelation(.duplicateOf, from: duplicate.id, to: original.id, by: context.agent.id)
        let change = try context.store.updateIssue(duplicate.id, IssuePatch(stateId: closed.id), by: context.agent.id)
        let presenter = Presenter(store: context.store, snapshot: try context.store.snapshot())
        return ["issue": try presenter.summary(change.issue), "duplicate_of": .string(original.identifier)]
    }

    private static func relationArguments(_ arguments: Arguments) throws -> (String, RelationType, String) {
        let typeName = try arguments.requiredString("type").lowercased()
        guard let type = RelationType(rawValue: typeName) else {
            throw TrackaroError.noMatch(entity: "relation type", reference: typeName, options: relationTypes)
        }
        return (try arguments.requiredString("issue"), type, try arguments.requiredString("related"))
    }

    private static func relations(of reference: String, context: ToolContext) throws -> Value {
        let issue = try context.store.issue(reference)
        let relations = try context.store.relations(of: issue.id)
        let identifiers = try context.store.identifiers(forIssueIds: relations.map(\.relatedIssueId))
        return [
            "issue": .string(issue.identifier),
            "relations": .array(relations.map {
                ["type": .string($0.type.rawValue), "issue": .string(identifiers[$0.relatedIssueId] ?? $0.relatedIssueId)]
            }),
        ]
    }
}
