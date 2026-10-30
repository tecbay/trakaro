import Foundation
import MCP
import TrackaroCore

/// Shapes stored rows into what an agent needs: names instead of ids, no empty fields.
struct Presenter {
    let store: TrackaroStore
    let snapshot: WorkspaceSnapshot

    /// One line per issue in a listing.
    func summaries(_ issues: [Issue]) throws -> [Value] {
        let labelMap = try store.labelIds(forIssues: issues.map(\.id))
        let parents = try store.identifiers(forIssueIds: issues.compactMap(\.parentId))
        return issues.map { summary($0, labelIds: labelMap[$0.id] ?? [], parentIdentifier: $0.parentId.flatMap { parents[$0] }) }
    }

    func summary(_ issue: Issue) throws -> Value {
        try summaries([issue])[0]
    }

    private func summary(_ issue: Issue, labelIds: [String], parentIdentifier: String?) -> Value {
        var object = ObjectBuilder()
        object.set("identifier", issue.identifier)
        object.set("title", issue.title)
        let state = snapshot.statesById[issue.stateId]
        object.set("state", state?.name)
        object.set("category", state?.category.rawValue)
        if issue.priority != .none { object.set("priority", issue.priority.name) }
        object.set("assignee", issue.assigneeId.flatMap { snapshot.membersById[$0]?.name })
        object.set("labels", .array(labelIds.compactMap { snapshot.labelsById[$0]?.name }.sorted().map(Value.string)))
        object.set("project", issue.projectId.flatMap { snapshot.projectsById[$0]?.name })
        object.set("cycle", issue.cycleId.flatMap { snapshot.cyclesById[$0]?.number })
        object.set("parent", parentIdentifier)
        object.set("estimate", issue.estimate)
        object.set("due", issue.dueDate?.description)
        if issue.archivedAt != nil { object.set("archived", true) }
        return object.value
    }

    /// Everything about one issue: the summary plus description, dates, relations and children.
    func detail(_ issue: Issue) throws -> Value {
        guard case let .object(fields) = try summary(issue) else { return .null }
        var object = ObjectBuilder()
        for (key, value) in fields { object.set(key, value) }
        object.set("id", issue.id)
        object.set("team", snapshot.teamsById[issue.teamId]?.key)
        object.set("description", issue.description.isEmpty ? nil : issue.description)
        object.set("milestone", issue.milestoneId.flatMap { snapshot.milestonesById[$0]?.name })
        object.set("creator", snapshot.membersById[issue.creatorId]?.name)
        object.set("created_at", Output.timestamp(issue.createdAt))
        object.set("updated_at", Output.timestamp(issue.updatedAt))
        object.set("started_at", Output.timestamp(issue.startedAt))
        object.set("completed_at", Output.timestamp(issue.completedAt))
        object.set("canceled_at", Output.timestamp(issue.canceledAt))
        object.set("version", issue.version)

        let relations = try store.relations(of: issue.id)
        let related = try store.identifiers(forIssueIds: relations.map(\.relatedIssueId))
        object.set("relations", .array(relations.map { relation in
            ["type": .string(relation.type.rawValue), "issue": .string(related[relation.relatedIssueId] ?? relation.relatedIssueId)]
        }))
        if try store.isBlocked(issue.id) { object.set("blocked", true) }

        let children = try store.children(of: issue.id)
        object.set("sub_issues", .array(children.map { child in
            var entry = ObjectBuilder()
            entry.set("identifier", child.identifier)
            entry.set("title", child.title)
            entry.set("state", snapshot.statesById[child.stateId]?.name)
            return entry.value
        }))
        let comments = try store.commentCount(issueId: issue.id)
        if comments > 0 { object.set("comments", comments) }
        return object.value
    }

    func comment(_ comment: Comment) -> Value {
        var object = ObjectBuilder()
        object.set("id", comment.id)
        object.set("author", snapshot.membersById[comment.authorId]?.name)
        object.set("body", comment.body)
        object.set("created_at", Output.timestamp(comment.createdAt))
        object.set("reply_to", comment.parentId)
        if comment.editedAt != nil { object.set("edited", true) }
        return object.value
    }

    /// One history entry, with stored ids translated to the names they had.
    func activity(_ entry: IssueActivity) throws -> Value {
        var object = ObjectBuilder()
        object.set("at", Output.timestamp(entry.createdAt))
        object.set("by", snapshot.membersById[entry.memberId]?.name)
        object.set("field", entry.field.rawValue)
        object.set("from", try readable(entry.fromValue, field: entry.field))
        object.set("to", try readable(entry.toValue, field: entry.field))
        return object.value
    }

    private func readable(_ json: String?, field: IssueField) throws -> Value? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let value = try JSONDecoder().decode(Value.self, from: data)
        switch field {
        case .state:
            return value.stringValue.map { .string(snapshot.statesById[$0]?.name ?? $0) }
        case .assignee:
            return value.stringValue.map { .string(snapshot.membersById[$0]?.name ?? $0) }
        case .project:
            return value.stringValue.map { .string(snapshot.projectsById[$0]?.name ?? $0) }
        case .milestone:
            return value.stringValue.map { .string(snapshot.milestonesById[$0]?.name ?? $0) }
        case .cycle:
            return value.stringValue.map { id in snapshot.cyclesById[id].map { .int($0.number) } ?? .string(id) }
        case .parent:
            guard let id = value.stringValue else { return value }
            return .string(try store.identifiers(forIssueIds: [id])[id] ?? id)
        case .labels:
            return value.arrayValue.map { ids in .array(ids.compactMap(\.stringValue).map { .string(snapshot.labelsById[$0]?.name ?? $0) }) }
        default:
            return value
        }
    }

    func cycle(_ cycle: Cycle, now: Date) -> Value {
        var object = ObjectBuilder()
        object.set("number", cycle.number)
        object.set("name", cycle.name)
        object.set("team", snapshot.teamsById[cycle.teamId]?.key)
        object.set("starts_at", Output.timestamp(cycle.startsAt))
        object.set("ends_at", Output.timestamp(cycle.endsAt))
        object.set("completed_at", Output.timestamp(cycle.completedAt))
        let active = cycle.completedAt == nil && cycle.startsAt <= now && now < cycle.endsAt
        if active { object.set("active", true) }
        return object.value
    }

    func project(_ project: Project) -> Value {
        var object = ObjectBuilder()
        object.set("name", project.name)
        object.set("slug", project.slug)
        object.set("status", project.status.rawValue)
        if project.health != .noUpdate { object.set("health", project.health.rawValue) }
        object.set("summary", project.summary.isEmpty ? nil : project.summary)
        object.set("lead", project.leadId.flatMap { snapshot.membersById[$0]?.name })
        object.set("start_date", project.startDate?.description)
        object.set("target_date", project.targetDate?.description)
        object.set("milestones", .array(snapshot.milestones.filter { $0.projectId == project.id }.map { .string($0.name) }))
        if project.archivedAt != nil { object.set("archived", true) }
        return object.value
    }

    func progress(_ progress: CycleProgress, now: Date) -> Value {
        var object = ObjectBuilder()
        object.set("cycle", cycle(progress.cycle, now: now))
        object.set("issues", progress.issueCount)
        object.set("open", progress.openCount)
        object.set("completed", progress.completedCount)
        object.set("canceled", progress.canceledCount)
        object.set("by_category", .object(Dictionary(uniqueKeysWithValues: progress.countByCategory.map { ($0.key.rawValue, Value.int($0.value)) })))
        object.set("points_total", progress.totalEstimate)
        object.set("points_completed", progress.completedEstimate)
        if progress.issueCount > 0 {
            let percent = Int((Double(progress.completedCount) / Double(max(progress.issueCount - progress.canceledCount, 1)) * 100).rounded())
            object.set("percent_complete", percent)
        }
        return object.value
    }
}
