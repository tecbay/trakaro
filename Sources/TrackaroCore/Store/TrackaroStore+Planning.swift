import Foundation
import GRDB

extension TrackaroStore {
    // MARK: - Projects

    @discardableResult
    public func createProject(
        name: String, summary: String = "", status: ProjectStatus = .planned, leadId: String? = nil,
        startDate: CalendarDate? = nil, targetDate: CalendarDate? = nil, by memberId: String
    ) throws -> Project {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TrackaroError.invalid(field: "name", message: "A project needs a name.") }
        if let startDate, let targetDate, targetDate < startDate {
            throw TrackaroError.invalid(field: "targetDate", message: "The target date is before the start date.")
        }
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            if let leadId { _ = try requireMember(db, leadId) }
            let slug = try uniqueSlug(db, for: name)
            let last = try String.fetchOne(db, sql: "SELECT MAX(sortKey) FROM project")
            let project = Project(
                id: newId(), name: name, slug: slug, summary: summary, description: "", status: status, health: .noUpdate,
                leadId: leadId, startDate: startDate, targetDate: targetDate, sortKey: try sortKey(between: last, and: nil),
                createdAt: now, updatedAt: now, archivedAt: nil
            )
            try project.insert(db)
            try recordChange(db, model: "project", id: project.id, action: .insert, by: memberId, at: now, snapshot: project)
            return project
        }
    }

    public func projects(includeArchived: Bool = false) throws -> [Project] {
        try writer.read { db in
            var request = Project.order(Column("sortKey"))
            if !includeArchived { request = request.filter(Column("archivedAt") == nil) }
            return try request.fetchAll(db)
        }
    }

    /// Lowercase words joined by dashes, with a numeric suffix when the slug is taken.
    static func slugify(_ name: String) -> String {
        let words = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "project" : String(slug.prefix(64))
    }

    private func uniqueSlug(_ db: Database, for name: String) throws -> String {
        let base = Self.slugify(name)
        var candidate = base
        var suffix = 2
        while try Project.filter(Column("slug") == candidate && Column("archivedAt") == nil).fetchCount(db) > 0 {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: - Milestones

    @discardableResult
    public func createMilestone(projectId: String, name: String, targetDate: CalendarDate? = nil, by memberId: String) throws -> Milestone {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TrackaroError.invalid(field: "name", message: "A milestone needs a name.") }
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            guard try Project.fetchOne(db, key: projectId) != nil else {
                throw TrackaroError.notFound(entity: "project", reference: projectId)
            }
            let last = try String.fetchOne(db, sql: "SELECT MAX(sortKey) FROM milestone WHERE projectId = ?", arguments: [projectId])
            let milestone = Milestone(
                id: newId(), projectId: projectId, name: name, description: "", targetDate: targetDate,
                sortKey: try sortKey(between: last, and: nil), createdAt: now, updatedAt: now
            )
            try milestone.insert(db)
            try recordChange(db, model: "milestone", id: milestone.id, action: .insert, by: memberId, at: now, snapshot: milestone)
            return milestone
        }
    }

    public func milestones(projectId: String) throws -> [Milestone] {
        try writer.read { db in
            try Milestone.filter(Column("projectId") == projectId).order(Column("sortKey")).fetchAll(db)
        }
    }

    // MARK: - Cycles

    public static let defaultCycleLength: TimeInterval = 7 * 24 * 60 * 60

    /// Creates the team's next cycle. Without dates it starts when the previous cycle ends (or now) and lasts a week.
    @discardableResult
    public func createCycle(teamId: String, name: String? = nil, startsAt: Date? = nil, endsAt: Date? = nil, by memberId: String) throws -> Cycle {
        try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            let team = try activeTeam(db, teamId)
            let previous = try Cycle.filter(Column("teamId") == team.id).order(Column("number").desc).fetchOne(db)
            let start = startsAt ?? previous?.endsAt ?? now
            let end = endsAt ?? start.addingTimeInterval(Self.defaultCycleLength)
            guard end > start else { throw TrackaroError.invalid(field: "endsAt", message: "A cycle must end after it starts.") }
            let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cycle = Cycle(
                id: newId(), teamId: team.id, number: (previous?.number ?? 0) + 1,
                name: trimmedName?.isEmpty == false ? trimmedName : nil,
                startsAt: start, endsAt: end, completedAt: nil, createdAt: now, updatedAt: now
            )
            try cycle.insert(db)
            try recordChange(db, model: "cycle", id: cycle.id, action: .insert, by: memberId, at: now, snapshot: cycle)
            return cycle
        }
    }

    public func cycles(teamId: String) throws -> [Cycle] {
        try writer.read { db in
            try Cycle.filter(Column("teamId") == teamId).order(Column("number")).fetchAll(db)
        }
    }
}
