import Foundation
import MCP
import TrackaroCore

enum IssueTools {
    static let maxBatch = 50

    static var all: [ToolDefinition] {
        [searchIssues, getIssues, createIssue, createSubIssues, updateIssue, moveIssue, bulkUpdateIssues, archiveIssue]
    }

    // MARK: Shared schema fragments

    static let issueRef = JSONSchema.string("Issue identifier such as ENG-42, or an issue id.")
    static let priorityNames = Priority.allCases.map(\.name)

    static var editableFields: [String: Value] {
        [
            "title": JSONSchema.string("New title."),
            "description": JSONSchema.string("Full markdown description. Replaces the existing one.", nullable: true),
            "state": JSONSchema.string("Workflow state name in the issue's team, such as \"In Progress\". A category name works when it is unambiguous."),
            "priority": JSONSchema.string("Priority.", oneOf: priorityNames),
            "assignee": JSONSchema.string("\"me\" for the user, \"self\" for you, a member name, or null to unassign.", nullable: true),
            "estimate": JSONSchema.integer("Points, 0 to 1000, or null to clear.", minimum: 0, maximum: 1000, nullable: true),
            "due_date": JSONSchema.string("Due date as YYYY-MM-DD, or null to clear.", nullable: true),
            "project": JSONSchema.string("Project name or slug, or null to clear.", nullable: true),
            "milestone": JSONSchema.string("Milestone name in the issue's project, or null to clear. Sets the project when the issue has none.", nullable: true),
            "cycle": JSONSchema.string("\"active\", a cycle number, or null to clear.", nullable: true),
            "parent": JSONSchema.string("Parent issue identifier, or null to make it top level.", nullable: true),
        ]
    }

    static let labelEdits: [String: Value] = [
        "labels": JSONSchema.array("Replace all labels with these names.", of: JSONSchema.string("Label name.")),
        "add_labels": JSONSchema.array("Label names to add.", of: JSONSchema.string("Label name.")),
        "remove_labels": JSONSchema.array("Label names to remove.", of: JSONSchema.string("Label name.")),
    ]

    // MARK: Filters

    /// The arguments that make up a filter, shared by search_issues and save_view.
    static let filterProperties: [String: Value] = [
        "query": JSONSchema.string("Free text. Every word must match as a prefix."),
        "team": JSONSchema.string("Team key or name."),
        "state": JSONSchema.string("Workflow state name, such as \"In Review\". Matches that name in every team."),
        "category": JSONSchema.string(
            "State category. \"open\" is everything not completed or canceled; \"closed\" is completed or canceled.",
            oneOf: StateCategory.allCases.map(\.rawValue) + ["open", "closed"]
        ),
        "assignee": JSONSchema.string("\"me\", \"self\", a member name, or \"none\" for unassigned."),
        "label": JSONSchema.string("Label name."),
        "project": JSONSchema.string("Project name or slug, or \"none\"."),
        "priority": JSONSchema.string("Only this priority.", oneOf: priorityNames),
    ]

    /// A filter from the filter arguments, and the teams it covers: the named team, or every active team.
    static func issueFilter(from arguments: Arguments, resolver: Resolver) throws -> (IssueFilter, [Team]) {
        var filter = IssueFilter()
        filter.text = try arguments.string("query")
        let teams: [Team]
        if let reference = try arguments.string("team") {
            let team = try resolver.team(reference)
            teams = [team]
            filter.teamIds = [team.id]
        } else {
            teams = resolver.activeTeams
        }
        if let state = try arguments.string("state") {
            filter.stateIds = try resolver.stateIds(named: state, teams: teams)
        }
        if let category = try arguments.string("category")?.lowercased() {
            switch category {
            case "open": filter.stateCategories = StateCategory.allCases.filter(\.isOpen)
            case "closed": filter.stateCategories = [.completed, .canceled]
            default:
                guard let value = StateCategory(rawValue: category) else {
                    throw TrackaroError.noMatch(entity: "category", reference: category, options: StateCategory.allCases.map(\.rawValue) + ["open", "closed"])
                }
                filter.stateCategories = [value]
            }
        }
        if let assignee = try arguments.string("assignee") {
            filter.assigneeIds = [assignee.lowercased() == "none" ? IssueFilter.unset : try resolver.member(assignee).id]
        }
        if let label = try arguments.string("label") {
            filter.labelIds = try resolver.labelIds(named: label)
        }
        if let project = try arguments.string("project") {
            filter.projectIds = [project.lowercased() == "none" ? IssueFilter.unset : try resolver.project(project).id]
        }
        if let priority = try arguments.priority("priority") {
            filter.priorities = [priority]
        }
        return (filter, teams)
    }

    // MARK: search_issues

    static let searchIssues = ToolDefinition(
        name: "search_issues",
        title: "Search issues",
        description: """
            Find issues by text and filters. Returns one compact line per issue; call get_issues for descriptions, \
            relations and sub-issues. Text matches identifier, title and description by word prefix. \
            Use category "open" for unfinished work and assignee "me" or "self" for the user's or your own issues.
            """,
        inputSchema: JSONSchema.object(filterProperties.merging([
            "view": JSONSchema.string("Saved view name. Its filters apply first; the other arguments narrow further."),
            "cycle": JSONSchema.string("\"active\", a cycle number (needs team), or \"none\"."),
            "parent": JSONSchema.string("Only sub-issues of this issue."),
            "include_sub_issues": JSONSchema.boolean("Include issues that have a parent. Default true."),
            "include_archived": JSONSchema.boolean("Include archived issues. Default false."),
            "order": JSONSchema.string(
                "Sort order. Default \"relevance\" with a query, otherwise \"manual\" (board order).",
                oneOf: IssueQuery.Order.allCases.map(\.rawValue)
            ),
            "limit": JSONSchema.integer("Page size, 1 to 100. Default 25.", minimum: 1, maximum: 100),
            "cursor": JSONSchema.string("next_cursor from the previous page."),
        ]) { current, _ in current }),
        readOnly: true
    ) { context, arguments in
        let resolver = try Resolver(context)
        var base = IssueQuery()
        if let view = try arguments.string("view") {
            base = try context.store.view(view).issueFilter.applied(to: base)
        }
        let (filter, teams) = try issueFilter(from: arguments, resolver: resolver)
        var query = filter.applied(to: base)
        if let cycle = try arguments.string("cycle") {
            if cycle.lowercased() == "none" {
                query.cycle = ReferenceFilter.none
            } else if cycle.lowercased() == "active" {
                query.cycle = .anyOf(try teams.compactMap { try context.store.activeCycle(teamId: $0.id)?.id })
            } else {
                guard let team = teams.first, teams.count == 1 else {
                    throw TrackaroError.invalid(field: "cycle", message: "Pass team with a cycle number.")
                }
                query.cycle = .anyOf([try resolver.cycle(cycle, in: team).id])
            }
        }
        if let parent = try arguments.string("parent") {
            query.parentId = try resolver.issue(parent).id
        }
        query.includeSubIssues = try arguments.bool("include_sub_issues") ?? true
        query.includeArchived = try arguments.bool("include_archived") ?? false
        if let order = try arguments.string("order") {
            guard let value = IssueQuery.Order(rawValue: order.lowercased()) else {
                throw TrackaroError.noMatch(entity: "order", reference: order, options: IssueQuery.Order.allCases.map(\.rawValue))
            }
            query.order = value
        } else {
            query.order = query.text == nil ? .manual : .relevance
        }
        query.limit = min(max(try arguments.int("limit") ?? 25, 1), 100)
        if let cursor = try arguments.string("cursor") {
            guard let offset = Int(cursor), offset >= 0 else {
                throw TrackaroError.invalid(field: "cursor", message: "Pass next_cursor exactly as returned.")
            }
            query.offset = offset
        }

        let page = try context.store.queryIssues(query)
        let presenter = Presenter(store: context.store, snapshot: resolver.snapshot)
        var result = ObjectBuilder()
        result.setIssues(try presenter.summaries(page.issues))
        result.set("next_cursor", page.nextOffset.map(String.init))
        return result.value
    }

    // MARK: get_issues

    static let getIssues = ToolDefinition(
        name: "get_issues",
        title: "Get issues",
        description: """
            Full details for one or more issues: description, dates, relations, sub-issues and comment count. \
            Identifiers that do not resolve are listed under not_found instead of failing the call.
            """,
        inputSchema: JSONSchema.object([
            "issues": JSONSchema.array("Issue identifiers or ids.", of: issueRef, minItems: 1, maxItems: 25),
        ], required: ["issues"]),
        readOnly: true
    ) { context, arguments in
        let references = try arguments.strings("issues") ?? []
        guard references.count <= 25 else { throw TrackaroError.invalid(field: "issues", message: "At most 25 per call.") }
        let resolver = try Resolver(context)
        let presenter = Presenter(store: context.store, snapshot: resolver.snapshot)
        var found: [Value] = []
        var missing: [Value] = []
        for reference in references {
            do {
                found.append(try presenter.detail(try resolver.issue(reference)))
            } catch TrackaroError.notFound {
                missing.append(.string(reference))
            }
        }
        var result = ObjectBuilder()
        result.setIssues(found)
        result.set("not_found", .array(missing))
        return result.value
    }

    // MARK: create_issue

    static let createIssue = ToolDefinition(
        name: "create_issue",
        title: "Create issue",
        description: """
            Create one issue. It lands at the top of its state column, in the team's Backlog unless you pass state. \
            Labels must already exist; the error lists the available ones. Returns the new issue's details.
            """,
        inputSchema: JSONSchema.object(
            editableFields.merging([
                "team": JSONSchema.string("Team key or name. Optional when there is only one team."),
                "labels": JSONSchema.array("Label names.", of: JSONSchema.string("Label name.")),
            ]) { current, _ in current },
            required: ["title"]
        ),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let team: Team
        if let parentReference = try arguments.string("parent"), try arguments.string("team") == nil {
            let parent = try resolver.issue(parentReference)
            team = try resolver.team(parent.teamId)
        } else {
            team = try resolver.team(try arguments.string("team"))
        }
        let input = try newIssue(arguments, team: team, resolver: resolver)
        let issue = try context.store.createIssue(input, by: context.agent.id)
        return try Presenter(store: context.store, snapshot: context.store.snapshot()).detail(issue)
    }

    static func newIssue(_ arguments: Arguments, team: Team, resolver: Resolver) throws -> NewIssue {
        var input = NewIssue(teamId: team.id, title: try arguments.requiredString("title"))
        input.description = try arguments.text("description") ?? ""
        input.stateId = try arguments.string("state").map { try resolver.state($0, in: team).id }
        input.priority = try arguments.priority("priority") ?? .none
        input.assigneeId = try arguments.string("assignee").map { try resolver.member($0).id }
        input.estimate = try arguments.int("estimate")
        input.dueDate = try arguments.date("due_date")
        let project = try arguments.string("project").map { try resolver.project($0) }
        input.projectId = project?.id
        input.milestoneId = try arguments.string("milestone").map { try resolver.milestone($0, project: project).id }
        input.cycleId = try arguments.string("cycle").map { try resolver.cycle($0, in: team).id }
        input.parentId = try arguments.string("parent").map { try resolver.issue($0).id }
        input.labelIds = try resolver.labels(try arguments.strings("labels") ?? [], for: team).map(\.id)
        return input
    }

    // MARK: create_sub_issues

    static let createSubIssues = ToolDefinition(
        name: "create_sub_issues",
        title: "Create sub-issues",
        description: """
            Break an issue into sub-issues in one call. Every item is checked before anything is written, so a bad \
            state or label name creates nothing. Sub-issues join the parent's team.
            """,
        inputSchema: JSONSchema.object([
            "parent": issueRef,
            "issues": JSONSchema.array("Sub-issues to create, in order.", of: JSONSchema.object([
                "title": JSONSchema.string("Title."),
                "description": JSONSchema.string("Markdown description."),
                "state": JSONSchema.string("Workflow state name."),
                "priority": JSONSchema.string("Priority.", oneOf: priorityNames),
                "assignee": JSONSchema.string("\"me\", \"self\" or a member name."),
                "estimate": JSONSchema.integer("Points.", minimum: 0, maximum: 1000),
                "due_date": JSONSchema.string("YYYY-MM-DD."),
                "labels": JSONSchema.array("Label names.", of: JSONSchema.string("Label name.")),
            ], required: ["title"]), minItems: 1, maxItems: maxBatch),
        ], required: ["parent", "issues"]),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let parent = try resolver.issue(try arguments.requiredString("parent"))
        let team = try resolver.team(parent.teamId)
        let items = try arguments.objects("issues") ?? []
        guard (1...maxBatch).contains(items.count) else {
            throw TrackaroError.invalid(field: "issues", message: "Pass 1 to \(maxBatch) items.")
        }
        let allowed: Set<String> = ["title", "description", "state", "priority", "assignee", "estimate", "due_date", "labels"]
        var inputs: [NewIssue] = []
        for (index, item) in items.enumerated() {
            do {
                let unknown = Set(item.values.keys).subtracting(allowed).sorted()
                if !unknown.isEmpty {
                    throw TrackaroError.invalid(field: unknown.joined(separator: ", "), message: "Unknown field. Allowed: \(allowed.sorted().joined(separator: ", ")).")
                }
                var input = try newIssue(item, team: team, resolver: resolver)
                input.parentId = parent.id
                inputs.append(input)
            } catch let error as TrackaroError {
                throw TrackaroError.invalid(field: "issues[\(index)]", message: error.description)
            }
        }
        let created = try inputs.map { try context.store.createIssue($0, by: context.agent.id) }
        let presenter = Presenter(store: context.store, snapshot: try context.store.snapshot())
        var result = ObjectBuilder()
        result.set("parent", parent.identifier)
        result.setIssues(try presenter.summaries(created))
        return result.value
    }

    // MARK: update_issue

    static let updateIssue = ToolDefinition(
        name: "update_issue",
        title: "Update issue",
        description: """
            Change any fields of one issue. Omitted fields stay as they are; null clears a field. \
            Use state to change status within the team, and move_issue to change team or position. \
            Returns the issue and the list of fields that actually changed.
            """,
        inputSchema: JSONSchema.object(
            editableFields.merging(labelEdits) { current, _ in current }.merging(["issue": issueRef]) { current, _ in current },
            required: ["issue"]
        ),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let issue = try resolver.issue(try arguments.requiredString("issue"))
        let patch = try patch(arguments, for: issue, resolver: resolver)
        let labelChange = try labelEdit(arguments, for: issue, resolver: resolver)
        var changed: [IssueField] = []
        if patch != IssuePatch() {
            changed += try context.store.updateIssue(issue.id, patch, by: context.agent.id).changed
        }
        if let labelChange {
            changed += try labelChange(context).changed
        }
        let current = try context.store.issue(issue.id)
        let presenter = Presenter(store: context.store, snapshot: try context.store.snapshot())
        return ["issue": try presenter.summary(current), "changed": .array(changed.map { .string($0.rawValue) })]
    }

    /// Builds a patch from arguments, resolving names in the context of the issue's team and project.
    static func patch(_ arguments: Arguments, for issue: Issue, resolver: Resolver, allowText: Bool = true) throws -> IssuePatch {
        let team = try resolver.team(issue.teamId)
        var patch = IssuePatch()
        if allowText {
            patch.title = try arguments.string("title")
            if arguments.has("description") { patch.description = try arguments.text("description") ?? "" }
        }
        patch.stateId = try arguments.string("state").map { try resolver.state($0, in: team).id }
        if arguments.has("priority") { patch.priority = try arguments.priority("priority") ?? Priority.none }
        patch.assigneeId = try nullable(arguments, "assignee") { try resolver.member($0).id }
        if arguments.has("estimate") { patch.estimate = try arguments.int("estimate").map(FieldUpdate.set) ?? .clear }
        if arguments.has("due_date") { patch.dueDate = try arguments.date("due_date").map(FieldUpdate.set) ?? .clear }
        patch.projectId = try nullable(arguments, "project") { try resolver.project($0).id }
        let milestoneProject = (patch.projectId?.value ?? issue.projectId).flatMap { resolver.snapshot.projectsById[$0] }
        patch.milestoneId = try nullable(arguments, "milestone") { try resolver.milestone($0, project: milestoneProject).id }
        patch.cycleId = try nullable(arguments, "cycle") { try resolver.cycle($0, in: team).id }
        patch.parentId = try nullable(arguments, "parent") { try resolver.issue($0).id }
        return patch
    }

    /// Absent stays nil, explicit null clears, a string resolves to an id.
    static func nullable(_ arguments: Arguments, _ key: String, resolve: (String) throws -> String) throws -> FieldUpdate<String>? {
        guard arguments.has(key) else { return nil }
        guard let reference = try arguments.string(key) else { return .clear }
        return .set(try resolve(reference))
    }

    typealias LabelChange = (ToolContext) throws -> IssueChange

    /// Resolves label edits up front so a bad name fails before any write.
    static func labelEdit(_ arguments: Arguments, for issue: Issue, resolver: Resolver) throws -> LabelChange? {
        let team = try resolver.team(issue.teamId)
        if let replace = try arguments.strings("labels") {
            let ids = try resolver.labels(replace, for: team).map(\.id)
            return { try $0.store.setLabels(ids, on: issue.id, by: $0.agent.id) }
        }
        let add = try resolver.labels(try arguments.strings("add_labels") ?? [], for: team).map(\.id)
        let remove = try resolver.labels(try arguments.strings("remove_labels") ?? [], for: team).map(\.id)
        guard !add.isEmpty || !remove.isEmpty else { return nil }
        return { context in
            var changed: [IssueField] = []
            var latest: Issue?
            if !add.isEmpty {
                let change = try context.store.addLabels(add, to: issue.id, by: context.agent.id)
                changed += change.changed
                latest = change.issue
            }
            if !remove.isEmpty {
                let change = try context.store.removeLabels(remove, from: issue.id, by: context.agent.id)
                changed += change.changed
                latest = change.issue
            }
            return IssueChange(issue: latest ?? issue, changed: Array(Set(changed)))
        }
    }

    // MARK: move_issue

    static let moveIssue = ToolDefinition(
        name: "move_issue",
        title: "Move issue",
        description: """
            Change an issue's state, team or position in one step. after places it directly below that issue, before \
            directly above. Moving to another team gives it a new identifier; the old one keeps resolving. \
            Without a position, an issue that changes column goes to the top.
            """,
        inputSchema: JSONSchema.object([
            "issue": issueRef,
            "state": JSONSchema.string("Target state name (in the target team when changing team)."),
            "team": JSONSchema.string("Target team key or name."),
            "after": JSONSchema.string("Place directly below this issue in the same column."),
            "before": JSONSchema.string("Place directly above this issue in the same column."),
        ], required: ["issue"]),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let issue = try resolver.issue(try arguments.requiredString("issue"))
        let targetTeam = try arguments.string("team").map { try resolver.team($0) }
        var move = IssueMove()
        if let targetTeam, targetTeam.id != issue.teamId { move.teamId = targetTeam.id }
        move.stateId = try arguments.string("state").map { try resolver.state($0, in: targetTeam ?? resolver.team(issue.teamId)).id }
        move.afterIssue = try arguments.string("after")
        move.beforeIssue = try arguments.string("before")
        let change = try context.store.moveIssue(issue.id, move, by: context.agent.id)
        let presenter = Presenter(store: context.store, snapshot: try context.store.snapshot())
        var result = ObjectBuilder()
        result.set("issue", try presenter.summary(change.issue))
        result.set("changed", .array(change.changed.map { .string($0.rawValue) }))
        if change.issue.identifier != issue.identifier { result.set("previous_identifier", issue.identifier) }
        return result.value
    }

    // MARK: bulk_update_issues

    static let bulkUpdateIssues = ToolDefinition(
        name: "bulk_update_issues",
        title: "Bulk update issues",
        description: """
            Apply the same change to many issues. Names resolve per issue's team, so "Done" works across teams. \
            Every issue and name is checked before anything is written; failures are reported per issue.
            """,
        inputSchema: JSONSchema.object([
            "issues": JSONSchema.array("Issue identifiers or ids.", of: issueRef, minItems: 1, maxItems: maxBatch),
            "state": JSONSchema.string("Workflow state name."),
            "priority": JSONSchema.string("Priority.", oneOf: priorityNames),
            "assignee": JSONSchema.string("\"me\", \"self\", a member name, or null to unassign.", nullable: true),
            "estimate": JSONSchema.integer("Points, or null to clear.", minimum: 0, maximum: 1000, nullable: true),
            "due_date": JSONSchema.string("YYYY-MM-DD, or null to clear.", nullable: true),
            "project": JSONSchema.string("Project name or slug, or null to clear.", nullable: true),
            "cycle": JSONSchema.string("\"active\", a cycle number, or null to clear.", nullable: true),
            "add_labels": JSONSchema.array("Label names to add.", of: JSONSchema.string("Label name.")),
            "remove_labels": JSONSchema.array("Label names to remove.", of: JSONSchema.string("Label name.")),
        ], required: ["issues"]),
        readOnly: false
    ) { context, arguments in
        let references = try arguments.strings("issues") ?? []
        guard (1...maxBatch).contains(references.count) else {
            throw TrackaroError.invalid(field: "issues", message: "Pass 1 to \(maxBatch) issues.")
        }
        let resolver = try Resolver(context)
        var plans: [(Issue, IssuePatch, LabelChange?)] = []
        var failures: [Value] = []
        for reference in references {
            do {
                let issue = try resolver.issue(reference)
                plans.append((issue, try patch(arguments, for: issue, resolver: resolver, allowText: false), try labelEdit(arguments, for: issue, resolver: resolver)))
            } catch let error as TrackaroError {
                failures.append(["issue": .string(reference), "error": .string(error.description)])
            }
        }
        guard failures.isEmpty else {
            return ["updated": .array([]), "failed": .array(failures), "note": "Nothing was written because some issues could not be resolved."]
        }
        var updated: [Value] = []
        for (issue, patch, labelChange) in plans {
            do {
                var changed: [IssueField] = []
                if patch != IssuePatch() { changed += try context.store.updateIssue(issue.id, patch, by: context.agent.id).changed }
                if let labelChange { changed += try labelChange(context).changed }
                updated.append(["issue": .string(issue.identifier), "changed": .array(changed.map { .string($0.rawValue) })])
            } catch let error as TrackaroError {
                failures.append(["issue": .string(issue.identifier), "error": .string(error.description)])
            }
        }
        var result = ObjectBuilder()
        result.set("updated", .array(updated))
        result.set("failed", .array(failures))
        return result.value
    }

    // MARK: archive_issue

    static let archiveIssue = ToolDefinition(
        name: "archive_issue",
        title: "Archive issue",
        description: "Archive an issue, hiding it from lists and search, or restore it with archived false. Nothing is deleted.",
        inputSchema: JSONSchema.object([
            "issue": issueRef,
            "archived": JSONSchema.boolean("False restores the issue. Default true."),
        ], required: ["issue"]),
        readOnly: false
    ) { context, arguments in
        let reference = try arguments.requiredString("issue")
        let change = try (arguments.bool("archived") ?? true)
            ? context.store.archiveIssue(reference, by: context.agent.id)
            : context.store.unarchiveIssue(reference, by: context.agent.id)
        return ["issue": .string(change.issue.identifier), "archived": .bool(change.issue.archivedAt != nil), "changed": .bool(!change.changed.isEmpty)]
    }
}
