import Foundation
import GRDB

extension TrackaroStore {
    /// Creates a team with the default workflow. The key becomes the identifier prefix (`ENG` in `ENG-42`).
    @discardableResult
    public func createTeam(key: String, name: String, by memberId: String) throws -> Team {
        let key = key.trimmingCharacters(in: .whitespaces).uppercased()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TeamKey.isValid(key) else {
            throw TrackaroError.invalid(field: "key", message: "Use 2 to 6 letters or digits, starting with a letter.")
        }
        guard !name.isEmpty else { throw TrackaroError.invalid(field: "name", message: "A team needs a name.") }
        return try writer.write { db in
            if try Team.filter(sql: "key = ? COLLATE NOCASE AND archivedAt IS NULL", arguments: [key]).fetchCount(db) > 0 {
                throw TrackaroError.conflict(message: "A team with key \(key) already exists.", candidates: [])
            }
            let now = clock()
            let team = Team(id: newId(), key: key, name: name, issueCounter: 0, createdAt: now, updatedAt: now, archivedAt: nil)
            try team.insert(db)
            for (position, template) in DefaultWorkflow.states.enumerated() {
                let state = WorkflowState(id: newId(), teamId: team.id, name: template.name, category: template.category, color: template.color, position: position)
                try state.insert(db)
            }
            try recordChange(db, model: "team", id: team.id, action: .insert, by: memberId, at: now, snapshot: team)
            return team
        }
    }

    public func teams(includeArchived: Bool = false) throws -> [Team] {
        try writer.read { db in
            var request = Team.order(Column("createdAt"))
            if !includeArchived { request = request.filter(Column("archivedAt") == nil) }
            return try request.fetchAll(db)
        }
    }

    /// Resolves a team by id, key or name, case-insensitively.
    public func team(_ reference: String) throws -> Team {
        try writer.read { db in try resolveTeam(db, reference) }
    }

    func resolveTeam(_ db: Database, _ reference: String) throws -> Team {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byId = try Team.fetchOne(db, key: trimmed) { return byId }
        let matches = try Team
            .filter(sql: "archivedAt IS NULL AND (key = ? COLLATE NOCASE OR name = ? COLLATE NOCASE)", arguments: [trimmed, trimmed])
            .fetchAll(db)
        if matches.count == 1, let team = matches.first { return team }
        if matches.isEmpty { throw TrackaroError.notFound(entity: "team", reference: reference) }
        throw TrackaroError.conflict(message: "\"\(reference)\" matches several teams.", candidates: matches.map { "\($0.key) (\($0.id))" })
    }

    public func states(teamId: String) throws -> [WorkflowState] {
        try writer.read { db in try orderedStates(db, teamId: teamId) }
    }

    func orderedStates(_ db: Database, teamId: String) throws -> [WorkflowState] {
        try WorkflowState.filter(Column("teamId") == teamId).order(Column("position")).fetchAll(db)
    }

    func requireState(_ db: Database, _ id: String) throws -> WorkflowState {
        guard let state = try WorkflowState.fetchOne(db, key: id) else {
            throw TrackaroError.notFound(entity: "state", reference: id)
        }
        return state
    }

    func initialState(_ db: Database, teamId: String) throws -> WorkflowState {
        let states = try orderedStates(db, teamId: teamId)
        for category in DefaultWorkflow.preferredInitialCategories {
            if let state = states.first(where: { $0.category == category }) { return state }
        }
        guard let first = states.first else {
            throw TrackaroError.invalid(field: "team", message: "The team has no workflow states.")
        }
        return first
    }

    // MARK: - Labels

    @discardableResult
    public func createLabel(name: String, color: String, teamId: String?, by memberId: String) throws -> IssueLabel {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TrackaroError.invalid(field: "name", message: "A label needs a name.") }
        return try writer.write { db in
            if let teamId, try Team.fetchOne(db, key: teamId) == nil {
                throw TrackaroError.notFound(entity: "team", reference: teamId)
            }
            let duplicate = try IssueLabel
                .filter(sql: "name = ? COLLATE NOCASE AND teamId IS ?", arguments: [name, teamId])
                .fetchCount(db) > 0
            if duplicate { throw TrackaroError.conflict(message: "A label named \(name) already exists.", candidates: []) }
            let label = IssueLabel(id: newId(), teamId: teamId, name: name, color: color, createdAt: clock())
            try label.insert(db)
            try recordChange(db, model: "label", id: label.id, action: .insert, by: memberId, at: label.createdAt, snapshot: label)
            return label
        }
    }

    /// Labels usable on a team's issues: the team's own plus workspace-wide ones.
    public func labels(teamId: String? = nil) throws -> [IssueLabel] {
        try writer.read { db in
            let request = teamId.map { IssueLabel.filter(Column("teamId") == $0 || Column("teamId") == nil) } ?? IssueLabel.all()
            return try request.order(Column("name").collating(.nocase)).fetchAll(db)
        }
    }
}
