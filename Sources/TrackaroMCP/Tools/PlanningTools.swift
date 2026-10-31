import Foundation
import MCP
import TrackaroCore

/// Projects, milestones and cycles.
enum PlanningTools {
    static var all: [ToolDefinition] {
        [listProjects, createProject, updateProject, createMilestone, listCycles, createCycle, cycleProgress]
    }

    static let listProjects = ToolDefinition(
        name: "list_projects",
        title: "List projects",
        description: "Projects with status, health, dates, milestone names and progress. Use search_issues with project to see their issues.",
        inputSchema: JSONSchema.object([
            "include_archived": JSONSchema.boolean("Include archived projects. Default false."),
        ]),
        readOnly: true
    ) { context, arguments in
        let projects = try context.store.projects(includeArchived: try arguments.bool("include_archived") ?? false)
        let presenter = Presenter(store: context.store, snapshot: try context.store.snapshot())
        let progress = try context.store.projectsProgress()
        return ["projects": .array(projects.map { presenter.project($0, progress: progress[$0.id] ?? IssueProgress()) })]
    }

    static let createProject = ToolDefinition(
        name: "create_project",
        title: "Create project",
        description: "Create a project to group issues across teams toward one outcome.",
        inputSchema: JSONSchema.object([
            "name": JSONSchema.string("Project name."),
            "summary": JSONSchema.string("One-line summary."),
            "status": JSONSchema.string("Status. Default planned.", oneOf: ProjectStatus.allCases.map(\.rawValue)),
            "lead": JSONSchema.string("\"me\", \"self\" or a member name."),
            "start_date": JSONSchema.string("YYYY-MM-DD."),
            "target_date": JSONSchema.string("YYYY-MM-DD."),
        ], required: ["name"]),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        var status = ProjectStatus.planned
        if let name = try arguments.string("status") {
            guard let value = ProjectStatus(rawValue: name.lowercased()) else {
                throw TrackaroError.noMatch(entity: "status", reference: name, options: ProjectStatus.allCases.map(\.rawValue))
            }
            status = value
        }
        let project = try context.store.createProject(
            name: try arguments.requiredString("name"),
            summary: try arguments.string("summary") ?? "",
            status: status,
            leadId: try arguments.string("lead").map { try resolver.member($0).id },
            startDate: try arguments.date("start_date"),
            targetDate: try arguments.date("target_date"),
            by: context.agent.id
        )
        return Presenter(store: context.store, snapshot: try context.store.snapshot()).project(project)
    }

    static let updateProject = ToolDefinition(
        name: "update_project",
        title: "Update project",
        description: """
            Change a project's name, summary, status, health, lead or dates. Report health when you learn the project \
            is slipping or recovering. Omitted fields stay; null clears lead or dates.
            """,
        inputSchema: JSONSchema.object([
            "project": JSONSchema.string("Project name or slug."),
            "name": JSONSchema.string("New name."),
            "summary": JSONSchema.string("One-line summary."),
            "status": JSONSchema.string("Status.", oneOf: ProjectStatus.allCases.map(\.rawValue)),
            "health": JSONSchema.string("Health.", oneOf: ProjectHealth.allCases.map(\.rawValue)),
            "lead": JSONSchema.string("\"me\", \"self\", a member name, or null to clear.", nullable: true),
            "start_date": JSONSchema.string("YYYY-MM-DD, or null to clear.", nullable: true),
            "target_date": JSONSchema.string("YYYY-MM-DD, or null to clear.", nullable: true),
        ], required: ["project"]),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let project = try resolver.project(try arguments.requiredString("project"))
        var patch = ProjectPatch(name: try arguments.string("name"), summary: try arguments.string("summary"))
        if let name = try arguments.string("status") {
            guard let value = ProjectStatus(rawValue: name.lowercased()) else {
                throw TrackaroError.noMatch(entity: "status", reference: name, options: ProjectStatus.allCases.map(\.rawValue))
            }
            patch.status = value
        }
        if let name = try arguments.string("health") {
            guard let value = ProjectHealth(rawValue: name.lowercased()) else {
                throw TrackaroError.noMatch(entity: "health", reference: name, options: ProjectHealth.allCases.map(\.rawValue))
            }
            patch.health = value
        }
        patch.leadId = try IssueTools.nullable(arguments, "lead") { try resolver.member($0).id }
        if arguments.has("start_date") { patch.startDate = try arguments.date("start_date").map(FieldUpdate.set) ?? .clear }
        if arguments.has("target_date") { patch.targetDate = try arguments.date("target_date").map(FieldUpdate.set) ?? .clear }
        let updated = try context.store.updateProject(project.id, patch, by: context.agent.id)
        let presenter = Presenter(store: context.store, snapshot: try context.store.snapshot())
        return presenter.project(updated, progress: try context.store.projectsProgress()[updated.id] ?? IssueProgress())
    }

    static let createMilestone = ToolDefinition(
        name: "create_milestone",
        title: "Create milestone",
        description: "Add a milestone to a project. Milestones are added in order, last one at the end.",
        inputSchema: JSONSchema.object([
            "project": JSONSchema.string("Project name or slug."),
            "name": JSONSchema.string("Milestone name."),
            "target_date": JSONSchema.string("YYYY-MM-DD."),
        ], required: ["project", "name"]),
        readOnly: false
    ) { context, arguments in
        let project = try Resolver(context).project(try arguments.requiredString("project"))
        let milestone = try context.store.createMilestone(
            projectId: project.id, name: try arguments.requiredString("name"), targetDate: try arguments.date("target_date"), by: context.agent.id
        )
        var result = ObjectBuilder()
        result.set("project", project.name)
        result.set("milestone", milestone.name)
        result.set("target_date", milestone.targetDate?.description)
        return result.value
    }

    static let listCycles = ToolDefinition(
        name: "list_cycles",
        title: "List cycles",
        description: "A team's cycles (sprints) in order, with the active one flagged.",
        inputSchema: JSONSchema.object([
            "team": JSONSchema.string("Team key or name. Optional when there is only one team."),
        ]),
        readOnly: true
    ) { context, arguments in
        let resolver = try Resolver(context)
        let team = try resolver.team(try arguments.string("team"))
        let presenter = Presenter(store: context.store, snapshot: resolver.snapshot)
        let now = context.store.now()
        return ["team": .string(team.key), "cycles": .array(try context.store.cycles(teamId: team.id).map { presenter.cycle($0, now: now) })]
    }

    static let createCycle = ToolDefinition(
        name: "create_cycle",
        title: "Create cycle",
        description: """
            Create a team's next cycle. Without dates it starts when the previous cycle ends (or today) and lasts \
            one week. Dates are calendar days in the user's time zone; the cycle ends at the start of ends_on.
            """,
        inputSchema: JSONSchema.object([
            "team": JSONSchema.string("Team key or name. Optional when there is only one team."),
            "name": JSONSchema.string("Optional name, such as \"Launch polish\"."),
            "starts_on": JSONSchema.string("YYYY-MM-DD."),
            "ends_on": JSONSchema.string("YYYY-MM-DD, after starts_on."),
        ]),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let team = try resolver.team(try arguments.string("team"))
        let cycle = try context.store.createCycle(
            teamId: team.id,
            name: try arguments.string("name"),
            startsAt: try arguments.date("starts_on").map(startOfDay),
            endsAt: try arguments.date("ends_on").map(startOfDay),
            by: context.agent.id
        )
        return Presenter(store: context.store, snapshot: try context.store.snapshot()).cycle(cycle, now: context.store.now())
    }

    static let cycleProgress = ToolDefinition(
        name: "cycle_progress",
        title: "Cycle progress",
        description: "Issue counts by category and points for a cycle. Defaults to the team's active cycle.",
        inputSchema: JSONSchema.object([
            "team": JSONSchema.string("Team key or name. Optional when there is only one team."),
            "cycle": JSONSchema.string("\"active\" (default), a cycle number, or an id."),
        ]),
        readOnly: true
    ) { context, arguments in
        let resolver = try Resolver(context)
        let team = try resolver.team(try arguments.string("team"))
        let cycle = try resolver.cycle(try arguments.string("cycle") ?? "active", in: team)
        let presenter = Presenter(store: context.store, snapshot: resolver.snapshot)
        return presenter.progress(try context.store.cycleProgress(cycleId: cycle.id), now: context.store.now())
    }

    private static func startOfDay(_ date: CalendarDate) -> Date {
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        return Calendar.current.date(from: components) ?? Date()
    }
}
