import Foundation
import GRDB

extension TrackaroStore {
    static let maxTitleLength = 512
    static let maxDescriptionLength = 500_000
    static let estimateRange = 0...1000

    // MARK: - Reading

    /// Resolves an issue by id, by identifier (`ENG-42`, any case), or by an identifier it had before moving teams.
    public func issue(_ reference: String) throws -> Issue {
        try writer.read { db in try resolveIssue(db, reference) }
    }

    /// A team's issues in board order: by workflow state position, then manual order within each state.
    public func issues(teamId: String, includeArchived: Bool = false) throws -> [Issue] {
        try writer.read { db in
            try Issue.fetchAll(db, sql: """
                SELECT issue.* FROM issue
                JOIN workflowState ON workflowState.id = issue.stateId
                WHERE issue.teamId = ? AND (issue.archivedAt IS NULL OR ?)
                ORDER BY workflowState.position, issue.sortKey
                """, arguments: [teamId, includeArchived])
        }
    }

    public func children(of issueId: String) throws -> [Issue] {
        try writer.read { db in
            try Issue.filter(Column("parentId") == issueId).order(Column("createdAt")).fetchAll(db)
        }
    }

    public func activity(issueId: String) throws -> [IssueActivity] {
        try writer.read { db in
            try IssueActivity.filter(Column("issueId") == issueId).order(Column("createdAt"), Column.rowID).fetchAll(db)
        }
    }

    public func labels(forIssue issueId: String) throws -> [IssueLabel] {
        try writer.read { db in try labelsOf(db, issueId) }
    }

    func requireIssue(_ db: Database, _ id: String) throws -> Issue {
        guard let issue = try Issue.filter(Column("id") == id).fetchOne(db) else {
            throw TrackaroError.notFound(entity: "issue", reference: id)
        }
        return issue
    }

    func resolveIssue(_ db: Database, _ reference: String) throws -> Issue {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byId = try Issue.filter(Column("id") == trimmed).fetchOne(db) { return byId }
        if let key = IssueKey(trimmed) {
            if let byIdentifier = try Issue.filter(Column("identifier") == key.description).fetchOne(db) {
                return byIdentifier
            }
            if let alias = try IssueAlias.fetchOne(db, key: key.description) {
                return try requireIssue(db, alias.issueId)
            }
        }
        throw TrackaroError.notFound(entity: "issue", reference: reference)
    }

    func labelsOf(_ db: Database, _ issueId: String) throws -> [IssueLabel] {
        try IssueLabel.fetchAll(db, sql: """
            SELECT label.* FROM label
            JOIN issueLabel ON issueLabel.labelId = label.id
            WHERE issueLabel.issueId = ?
            ORDER BY label.name COLLATE NOCASE
            """, arguments: [issueId])
    }

    // MARK: - Creating

    public func createIssue(_ input: NewIssue, by memberId: String) throws -> Issue {
        let title = try Self.validatedTitle(input.title)
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            let team = try activeTeam(db, input.teamId)
            let initial = try initialState(db, teamId: team.id)
            let number = try allocateNumber(db, teamId: team.id, at: now)
            var issue = Issue(
                seq: nil, id: newId(), teamId: team.id, number: number, identifier: "\(team.key)-\(number)",
                title: title, description: "", stateId: initial.id, priority: .none, estimate: nil, dueDate: nil,
                sortKey: "", parentId: nil, projectId: nil, milestoneId: nil, cycleId: nil, assigneeId: nil,
                creatorId: memberId, startedAt: nil, completedAt: nil, canceledAt: nil, stateEnteredAt: now,
                createdAt: now, updatedAt: now, archivedAt: nil, version: 1
            )
            issue.stateTimestamps = issue.stateTimestamps.entering(initial.category, at: now)
            let patch = IssuePatch(
                description: input.description.isEmpty ? nil : input.description,
                stateId: input.stateId,
                priority: input.priority == .none ? nil : input.priority,
                estimate: input.estimate.map(FieldUpdate.set),
                dueDate: input.dueDate.map(FieldUpdate.set),
                assigneeId: input.assigneeId.map(FieldUpdate.set),
                parentId: input.parentId.map(FieldUpdate.set),
                projectId: input.projectId.map(FieldUpdate.set),
                milestoneId: input.milestoneId.map(FieldUpdate.set),
                cycleId: input.cycleId.map(FieldUpdate.set)
            )
            _ = try applyPatch(db, to: &issue, patch, at: now)
            issue.sortKey = try topSortKey(db, teamId: issue.teamId, stateId: issue.stateId, excluding: issue.id)
            try issue.insert(db)
            for label in try validatedLabels(db, ids: input.labelIds, teamId: issue.teamId) {
                try IssueLabelLink(issueId: issue.id, labelId: label.id).insert(db)
            }
            try recordActivity(db, issueId: issue.id, by: memberId, field: .created, from: nil, to: Self.json(issue.identifier), at: now)
            try recordChange(db, model: "issue", id: issue.id, action: .insert, by: memberId, at: now, snapshot: issue)
            return issue
        }
    }

    func allocateNumber(_ db: Database, teamId: String, at now: Date) throws -> Int {
        try db.execute(sql: "UPDATE team SET issueCounter = issueCounter + 1, updatedAt = ? WHERE id = ?", arguments: [now, teamId])
        guard let number = try Int.fetchOne(db, sql: "SELECT issueCounter FROM team WHERE id = ?", arguments: [teamId]) else {
            throw TrackaroError.notFound(entity: "team", reference: teamId)
        }
        return number
    }

    func activeTeam(_ db: Database, _ id: String) throws -> Team {
        guard let team = try Team.fetchOne(db, key: id) else { throw TrackaroError.notFound(entity: "team", reference: id) }
        guard team.archivedAt == nil else { throw TrackaroError.invalid(field: "team", message: "\(team.key) is archived.") }
        return team
    }

    // MARK: - Updating

    public func updateIssue(_ id: String, _ patch: IssuePatch, expecting expected: IssuePatch? = nil, by memberId: String) throws -> IssueChange {
        try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            var issue = try resolveIssue(db, id)
            if let expected {
                let unmet = Self.unmetExpectations(issue, expected)
                if !unmet.isEmpty {
                    throw TrackaroError.conflict(
                        message: "\(issue.identifier) changed since it was read: \(unmet.map(\.rawValue).joined(separator: ", ")).",
                        candidates: []
                    )
                }
            }
            let deltas = try applyPatch(db, to: &issue, patch, at: now)
            guard !deltas.isEmpty else { return IssueChange(issue: issue, changed: []) }
            try commit(db, &issue, deltas, by: memberId, at: now)
            return IssueChange(issue: issue, changed: deltas.map(\.field))
        }
    }

    public func archiveIssue(_ id: String, by memberId: String) throws -> IssueChange {
        try setArchived(id, archived: true, by: memberId)
    }

    public func unarchiveIssue(_ id: String, by memberId: String) throws -> IssueChange {
        try setArchived(id, archived: false, by: memberId)
    }

    private func setArchived(_ id: String, archived: Bool, by memberId: String) throws -> IssueChange {
        try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            var issue = try resolveIssue(db, id)
            guard (issue.archivedAt != nil) != archived else { return IssueChange(issue: issue, changed: []) }
            issue.archivedAt = archived ? now : nil
            let delta = FieldDelta(field: .archived, from: Self.json(!archived), to: Self.json(archived))
            try commit(db, &issue, [delta], by: memberId, at: now, action: archived ? .archive : .unarchive)
            return IssueChange(issue: issue, changed: [.archived])
        }
    }

    func commit(_ db: Database, _ issue: inout Issue, _ deltas: [FieldDelta], by memberId: String, at now: Date, action: ChangeAction = .update) throws {
        issue.version += 1
        issue.updatedAt = now
        try issue.update(db)
        for delta in deltas {
            try recordActivity(db, issueId: issue.id, by: memberId, field: delta.field, from: delta.from, to: delta.to, at: now)
        }
        try recordChange(db, model: "issue", id: issue.id, action: action, by: memberId, at: now, snapshot: issue)
    }

    static func validatedTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TrackaroError.invalid(field: "title", message: "A title is required.") }
        guard trimmed.count <= maxTitleLength else {
            throw TrackaroError.invalid(field: "title", message: "Keep titles under \(maxTitleLength) characters.")
        }
        return trimmed
    }

    static func unmetExpectations(_ issue: Issue, _ expected: IssuePatch) -> [IssueField] {
        var unmet: [IssueField] = []
        if let value = expected.title, value != issue.title { unmet.append(.title) }
        if let value = expected.description, value != issue.description { unmet.append(.description) }
        if let value = expected.stateId, value != issue.stateId { unmet.append(.state) }
        if let value = expected.priority, value != issue.priority { unmet.append(.priority) }
        if let update = expected.estimate, update.value != issue.estimate { unmet.append(.estimate) }
        if let update = expected.dueDate, update.value != issue.dueDate { unmet.append(.dueDate) }
        if let update = expected.assigneeId, update.value != issue.assigneeId { unmet.append(.assignee) }
        if let update = expected.parentId, update.value != issue.parentId { unmet.append(.parent) }
        if let update = expected.projectId, update.value != issue.projectId { unmet.append(.project) }
        if let update = expected.milestoneId, update.value != issue.milestoneId { unmet.append(.milestone) }
        if let update = expected.cycleId, update.value != issue.cycleId { unmet.append(.cycle) }
        return unmet
    }

    /// Validates and applies a patch in memory, returning one delta per field that actually changed.
    func applyPatch(_ db: Database, to issue: inout Issue, _ patch: IssuePatch, at now: Date) throws -> [FieldDelta] {
        var deltas: [FieldDelta] = []

        if let title = patch.title {
            let title = try Self.validatedTitle(title)
            if title != issue.title {
                deltas.append(FieldDelta(field: .title, from: Self.json(issue.title), to: Self.json(title)))
                issue.title = title
            }
        }

        if let description = patch.description, description != issue.description {
            guard description.count <= Self.maxDescriptionLength else {
                throw TrackaroError.invalid(field: "description", message: "Keep descriptions under \(Self.maxDescriptionLength) characters.")
            }
            deltas.append(FieldDelta(field: .description, from: nil, to: nil))
            issue.description = description
        }

        if let stateId = patch.stateId, stateId != issue.stateId {
            let state = try requireState(db, stateId)
            guard state.teamId == issue.teamId else {
                throw TrackaroError.invalid(field: "state", message: "\(state.name) belongs to another team. Use a move to change teams.")
            }
            deltas.append(FieldDelta(field: .state, from: Self.json(issue.stateId), to: Self.json(state.id)))
            issue.stateId = state.id
            issue.stateTimestamps = issue.stateTimestamps.entering(state.category, at: now)
        }

        if let priority = patch.priority, priority != issue.priority {
            deltas.append(FieldDelta(field: .priority, from: Self.json(issue.priority.name), to: Self.json(priority.name)))
            issue.priority = priority
        }

        if let update = patch.estimate, update.value != issue.estimate {
            if let estimate = update.value, !Self.estimateRange.contains(estimate) {
                throw TrackaroError.invalid(field: "estimate", message: "Use a whole number from 0 to \(Self.estimateRange.upperBound).")
            }
            deltas.append(FieldDelta(field: .estimate, from: Self.json(issue.estimate), to: Self.json(update.value)))
            issue.estimate = update.value
        }

        if let update = patch.dueDate, update.value != issue.dueDate {
            deltas.append(FieldDelta(field: .dueDate, from: Self.json(issue.dueDate), to: Self.json(update.value)))
            issue.dueDate = update.value
        }

        if let update = patch.assigneeId, update.value != issue.assigneeId {
            if let assigneeId = update.value { _ = try requireMember(db, assigneeId) }
            deltas.append(FieldDelta(field: .assignee, from: Self.json(issue.assigneeId), to: Self.json(update.value)))
            issue.assigneeId = update.value
        }

        if let update = patch.parentId, update.value != issue.parentId {
            if let parentId = update.value { try assertParentAllowed(db, child: issue.id, parent: parentId) }
            deltas.append(FieldDelta(field: .parent, from: Self.json(issue.parentId), to: Self.json(update.value)))
            issue.parentId = update.value
        }

        if let update = patch.projectId, update.value != issue.projectId {
            if let projectId = update.value, try Project.fetchOne(db, key: projectId) == nil {
                throw TrackaroError.notFound(entity: "project", reference: projectId)
            }
            deltas.append(FieldDelta(field: .project, from: Self.json(issue.projectId), to: Self.json(update.value)))
            issue.projectId = update.value
            if patch.milestoneId == nil, let milestoneId = issue.milestoneId,
               try Milestone.fetchOne(db, key: milestoneId)?.projectId != update.value {
                deltas.append(FieldDelta(field: .milestone, from: Self.json(milestoneId), to: nil))
                issue.milestoneId = nil
            }
        }

        if let update = patch.milestoneId, update.value != issue.milestoneId {
            if let milestoneId = update.value {
                guard let milestone = try Milestone.fetchOne(db, key: milestoneId) else {
                    throw TrackaroError.notFound(entity: "milestone", reference: milestoneId)
                }
                if issue.projectId == nil {
                    deltas.append(FieldDelta(field: .project, from: nil, to: Self.json(milestone.projectId)))
                    issue.projectId = milestone.projectId
                } else if issue.projectId != milestone.projectId {
                    throw TrackaroError.invalid(field: "milestone", message: "\(milestone.name) belongs to a different project than this issue.")
                }
            }
            deltas.append(FieldDelta(field: .milestone, from: Self.json(issue.milestoneId), to: Self.json(update.value)))
            issue.milestoneId = update.value
        }

        if let update = patch.cycleId, update.value != issue.cycleId {
            if let cycleId = update.value {
                guard let cycle = try Cycle.fetchOne(db, key: cycleId) else {
                    throw TrackaroError.notFound(entity: "cycle", reference: cycleId)
                }
                guard cycle.teamId == issue.teamId else {
                    throw TrackaroError.invalid(field: "cycle", message: "That cycle belongs to another team.")
                }
            }
            deltas.append(FieldDelta(field: .cycle, from: Self.json(issue.cycleId), to: Self.json(update.value)))
            issue.cycleId = update.value
        }

        return deltas
    }

    /// Rejects self-parenting and any parent that is already a descendant of the child.
    func assertParentAllowed(_ db: Database, child: String, parent: String) throws {
        guard parent != child else {
            throw TrackaroError.invalid(field: "parent", message: "An issue cannot be its own parent.")
        }
        var cursor: String? = try requireIssue(db, parent).id
        var visited: Set<String> = []
        while let current = cursor {
            if current == child {
                throw TrackaroError.invalid(field: "parent", message: "That would make the issue its own ancestor.")
            }
            guard visited.insert(current).inserted else { break }
            cursor = try String.fetchOne(db, sql: "SELECT parentId FROM issue WHERE id = ?", arguments: [current])
        }
    }

    // MARK: - Labels on issues

    public func addLabels(_ labelIds: [String], to issueId: String, by memberId: String) throws -> IssueChange {
        try changeLabels(on: issueId, requested: labelIds, by: memberId) { current, requested in current.union(requested) }
    }

    public func removeLabels(_ labelIds: [String], from issueId: String, by memberId: String) throws -> IssueChange {
        try changeLabels(on: issueId, requested: labelIds, by: memberId) { current, requested in current.subtracting(requested) }
    }

    public func setLabels(_ labelIds: [String], on issueId: String, by memberId: String) throws -> IssueChange {
        try changeLabels(on: issueId, requested: labelIds, by: memberId) { _, requested in requested }
    }

    private func changeLabels(
        on issueId: String, requested: [String], by memberId: String,
        combine: (Set<String>, Set<String>) -> Set<String>
    ) throws -> IssueChange {
        try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            var issue = try resolveIssue(db, issueId)
            let requestedIds = Set(try validatedLabels(db, ids: requested, teamId: issue.teamId).map(\.id))
            let current = Set(try String.fetchAll(db, sql: "SELECT labelId FROM issueLabel WHERE issueId = ?", arguments: [issue.id]))
            let next = combine(current, requestedIds)
            guard next != current else { return IssueChange(issue: issue, changed: []) }
            for removed in current.subtracting(next) {
                try IssueLabelLink(issueId: issue.id, labelId: removed).delete(db)
            }
            for added in next.subtracting(current) {
                try IssueLabelLink(issueId: issue.id, labelId: added).insert(db)
            }
            let delta = FieldDelta(field: .labels, from: Self.json(current.sorted()), to: Self.json(next.sorted()))
            try commit(db, &issue, [delta], by: memberId, at: now)
            return IssueChange(issue: issue, changed: [.labels])
        }
    }

    func validatedLabels(_ db: Database, ids: [String], teamId: String) throws -> [IssueLabel] {
        var seen: Set<String> = []
        var labels: [IssueLabel] = []
        for id in ids where seen.insert(id).inserted {
            guard let label = try IssueLabel.fetchOne(db, key: id) else {
                throw TrackaroError.notFound(entity: "label", reference: id)
            }
            if let labelTeam = label.teamId, labelTeam != teamId {
                throw TrackaroError.invalid(field: "labels", message: "\(label.name) belongs to another team.")
            }
            labels.append(label)
        }
        return labels
    }
}
