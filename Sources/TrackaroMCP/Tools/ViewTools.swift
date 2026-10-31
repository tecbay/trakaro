import Foundation
import MCP
import TrackaroCore

/// Saved views: named filters the user sees in the app's sidebar. get_workspace lists them and search_issues
/// takes `view` to read one.
enum ViewTools {
    static var all: [ToolDefinition] {
        [saveView, deleteView]
    }

    static let saveView = ToolDefinition(
        name: "save_view",
        title: "Save view",
        description: """
            Save a filter as a named view in the user's sidebar, such as "Ready for agent". Takes the same filters \
            as search_issues. Saving under an existing view's name replaces that view's filters.
            """,
        inputSchema: JSONSchema.object(IssueTools.filterProperties.merging([
            "name": JSONSchema.string("View name, unique ignoring case."),
            "layout": JSONSchema.string("How the app shows it. Default list.", oneOf: ViewLayout.allCases.map(\.rawValue)),
        ]) { current, _ in current }, required: ["name"]),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let name = try arguments.requiredString("name")
        let (filter, _) = try IssueTools.issueFilter(from: arguments, resolver: resolver)
        let layout = try arguments.string("layout").map { value in
            guard let layout = ViewLayout(rawValue: value.lowercased()) else {
                throw TrackaroError.noMatch(entity: "layout", reference: value, options: ViewLayout.allCases.map(\.rawValue))
            }
            return layout
        }
        let existing = resolver.snapshot.savedViews.first { $0.name.lowercased() == name.trimmingCharacters(in: .whitespaces).lowercased() }
        let view = if let existing {
            try context.store.updateView(existing.id, filter: filter, layout: layout, by: context.agent.id)
        } else {
            try context.store.createView(name: name, filter: filter, layout: layout ?? .list, by: context.agent.id)
        }
        let matching = try context.store.queryIssues(view.issueFilter.applied(to: IssueQuery(limit: TrackaroStore.maxPageSize)))
        var result = describe(view, snapshot: resolver.snapshot)
        result.set("replaced", existing != nil)
        result.set("matching_issues", matching.issues.count)
        return result.value
    }

    static let deleteView = ToolDefinition(
        name: "delete_view",
        title: "Delete view",
        description: "Delete a saved view. Its issues are not touched.",
        inputSchema: JSONSchema.object([
            "name": JSONSchema.string("View name."),
        ], required: ["name"]),
        readOnly: false,
        destructive: true
    ) { context, arguments in
        let view = try context.store.view(try arguments.requiredString("name"))
        try context.store.deleteView(view.id, by: context.agent.id)
        return ["deleted": .string(view.name)]
    }

    /// A view with its filter in the names agents use everywhere else.
    static func describe(_ view: SavedView, snapshot: WorkspaceSnapshot) -> ObjectBuilder {
        let filter = view.issueFilter
        func names(_ ids: [String]?, _ name: (String) -> String?) -> Value? {
            guard let ids else { return nil }
            let unique = ids.compactMap { $0 == IssueFilter.unset ? "none" : name($0) }.reduce(into: [String]()) { list, value in
                if !list.contains(value) { list.append(value) }
            }
            return .array(unique.map { .string($0) })
        }
        var object = ObjectBuilder()
        object.set("name", view.name)
        object.set("layout", view.layout.rawValue)
        var described = ObjectBuilder()
        described.set("query", filter.text)
        described.set("team", names(filter.teamIds) { snapshot.teamsById[$0]?.key })
        described.set("state", names(filter.stateIds) { snapshot.statesById[$0]?.name })
        described.set("category", filter.stateCategories.map { .array($0.map { .string($0.rawValue) }) })
        described.set("priority", filter.priorities.map { .array($0.map { .string($0.name) }) })
        described.set("assignee", names(filter.assigneeIds) { snapshot.membersById[$0]?.name })
        described.set("label", names(filter.labelIds) { snapshot.labelsById[$0]?.name })
        described.set("project", names(filter.projectIds) { snapshot.projectsById[$0]?.name })
        object.set("filter", described.value)
        return object
    }
}
