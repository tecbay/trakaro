import Foundation
import GRDB

/// Artifacts: files agents save to a project and the user browses in the app. A name is unique within its project
/// ignoring case, so saving under the same name is how an agent updates one.
extension TrackaroStore {
    /// The largest artifact accepted. Backups copy every artifact, so this keeps them a sensible size.
    public static let maxArtifactBytes = 25 * 1024 * 1024

    private static let summaryColumns = [
        "id", "projectId", "name", "summary", "mimeType", "byteCount", "creatorId", "updaterId", "version", "createdAt", "updatedAt",
    ].map { Column($0) }

    /// Artifacts newest first, across every project when `projectId` is nil. `query` matches name and summary.
    public func artifacts(projectId: String? = nil, query: String? = nil) throws -> [ArtifactSummary] {
        try writer.read { db in
            var request = ArtifactSummary.select(Self.summaryColumns).filter(Column("deletedAt") == nil)
            if let projectId { request = request.filter(Column("projectId") == projectId) }
            if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                let pattern = "%\(query)%"
                request = request.filter(Column("name").like(pattern) || Column("summary").like(pattern))
            }
            return try request.order(Column("updatedAt").desc, Column("id").desc).fetchAll(db)
        }
    }

    public func artifactCount(projectId: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact WHERE projectId = ? AND deletedAt IS NULL", arguments: [projectId]) ?? 0
        }
    }

    /// One artifact with its content, by id, or by name within a project.
    public func artifact(_ reference: String, projectId: String? = nil) throws -> Artifact {
        try writer.read { db in
            let row = try resolveArtifact(db, reference, projectId: projectId)
            let content = try Data.fetchOne(db, sql: "SELECT content FROM artifact WHERE id = ?", arguments: [row.id]) ?? Data()
            return Artifact(summary: row, content: content)
        }
    }

    /// Creates the artifact, or replaces the content of the one with this name in this project. A nil `summary` or
    /// `mimeType` keeps what an existing artifact has.
    @discardableResult
    public func saveArtifact(
        projectId: String, name: String, content: Data, summary: String? = nil, mimeType: String? = nil, by memberId: String
    ) throws -> (artifact: ArtifactSummary, created: Bool) {
        let name = try Self.artifactName(name)
        guard !content.isEmpty else { throw TrackaroError.invalid(field: "content", message: "An artifact needs some content.") }
        guard content.count <= Self.maxArtifactBytes else {
            throw TrackaroError.invalid(field: "content", message: "Artifacts can be up to \(Self.maxArtifactBytes / 1024 / 1024) MB; this one is \(content.count / 1024 / 1024) MB.")
        }
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            guard try Project.fetchOne(db, key: projectId) != nil else {
                throw TrackaroError.notFound(entity: "project", reference: projectId)
            }
            let existing = try ArtifactSummary.select(Self.summaryColumns)
                .filter(Column("projectId") == projectId && Column("deletedAt") == nil)
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [name])
                .fetchOne(db)
            if let existing {
                let type = mimeType.map { ArtifactType.resolve(mimeType: $0, name: name, content: content) } ?? existing.mimeType
                try db.execute(sql: """
                    UPDATE artifact SET name = ?, summary = ?, mimeType = ?, content = ?, byteCount = ?, updaterId = ?,
                        version = version + 1, updatedAt = ?
                    WHERE id = ?
                    """, arguments: [name, summary ?? existing.summary, type, content, content.count, memberId, now, existing.id])
                let saved = try resolveArtifact(db, existing.id, projectId: nil)
                try recordChange(db, model: "artifact", id: saved.id, action: .update, by: memberId, at: now, snapshot: saved)
                return (saved, false)
            }
            let id = newId()
            try db.execute(sql: """
                INSERT INTO artifact (id, projectId, name, summary, mimeType, content, byteCount, creatorId, updaterId, version, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """, arguments: [id, projectId, name, summary ?? "", ArtifactType.resolve(mimeType: mimeType, name: name, content: content),
                                 content, content.count, memberId, memberId, now, now])
            let saved = try resolveArtifact(db, id, projectId: nil)
            try recordChange(db, model: "artifact", id: id, action: .insert, by: memberId, at: now, snapshot: saved)
            return (saved, true)
        }
    }

    /// Hides an artifact. The row stays, so older backups and the change log keep making sense, and its name is free
    /// to use again.
    public func deleteArtifact(_ id: String, by memberId: String) throws {
        try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            let artifact = try resolveArtifact(db, id, projectId: nil)
            try db.execute(sql: "UPDATE artifact SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [now, now, artifact.id])
            try recordChange(db, model: "artifact", id: artifact.id, action: .delete, by: memberId, at: now, snapshot: ArtifactSummary?.none)
        }
    }

    private func resolveArtifact(_ db: Database, _ reference: String, projectId: String?) throws -> ArtifactSummary {
        var pool = ArtifactSummary.select(Self.summaryColumns).filter(Column("deletedAt") == nil)
        if let projectId { pool = pool.filter(Column("projectId") == projectId) }
        if let byId = try pool.filter(Column("id") == reference).fetchOne(db) { return byId }
        let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = try pool.filter(sql: "name = ? COLLATE NOCASE", arguments: [wanted]).fetchAll(db)
        if let only = matches.first, matches.count == 1 { return only }
        if matches.count > 1 {
            throw TrackaroError.conflict(message: "\"\(reference)\" names artifacts in several projects. Pass the project too.", candidates: [])
        }
        throw TrackaroError.noMatch(entity: "artifact", reference: reference, options: try pool.order(Column("name")).limit(50).fetchAll(db).map(\.name))
    }

    private static func artifactName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TrackaroError.invalid(field: "name", message: "An artifact needs a name.") }
        guard trimmed.count <= 200 else { throw TrackaroError.invalid(field: "name", message: "Keep artifact names to 200 characters.") }
        return trimmed
    }
}
