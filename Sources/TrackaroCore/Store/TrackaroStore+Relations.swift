import Foundation
import GRDB

extension TrackaroStore {
    // MARK: - Relations

    /// Links two issues and writes the inverse link, so `ENG-1 blocks ENG-2` also records `ENG-2 blocked_by ENG-1`.
    public func setRelation(_ type: RelationType, from issueRef: String, to relatedRef: String, by memberId: String) throws {
        try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            var issue = try resolveIssue(db, issueRef)
            var related = try resolveIssue(db, relatedRef)
            guard issue.id != related.id else {
                throw TrackaroError.invalid(field: "relation", message: "An issue cannot relate to itself.")
            }
            let exists = try IssueRelation
                .filter(Column("issueId") == issue.id && Column("relatedIssueId") == related.id && Column("type") == type.rawValue)
                .fetchCount(db) > 0
            guard !exists else { return }
            let forward = IssueRelation(issueId: issue.id, relatedIssueId: related.id, type: type, createdAt: now)
            try forward.insert(db)
            try IssueRelation(issueId: related.id, relatedIssueId: issue.id, type: type.inverse, createdAt: now).insert(db)
            let forwardText = "\(type.rawValue) \(related.identifier)"
            let inverseText = "\(type.inverse.rawValue) \(issue.identifier)"
            try commit(db, &issue, [FieldDelta(field: .relation, from: nil, to: Self.json(forwardText))], by: memberId, at: now)
            try commit(db, &related, [FieldDelta(field: .relation, from: nil, to: Self.json(inverseText))], by: memberId, at: now)
        }
    }

    public func removeRelation(_ type: RelationType, from issueRef: String, to relatedRef: String, by memberId: String) throws {
        try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            var issue = try resolveIssue(db, issueRef)
            var related = try resolveIssue(db, relatedRef)
            let removed = try IssueRelation
                .filter(Column("issueId") == issue.id && Column("relatedIssueId") == related.id && Column("type") == type.rawValue)
                .deleteAll(db)
            guard removed > 0 else { return }
            try IssueRelation
                .filter(Column("issueId") == related.id && Column("relatedIssueId") == issue.id && Column("type") == type.inverse.rawValue)
                .deleteAll(db)
            let forwardText = "\(type.rawValue) \(related.identifier)"
            let inverseText = "\(type.inverse.rawValue) \(issue.identifier)"
            try commit(db, &issue, [FieldDelta(field: .relation, from: Self.json(forwardText), to: nil)], by: memberId, at: now)
            try commit(db, &related, [FieldDelta(field: .relation, from: Self.json(inverseText), to: nil)], by: memberId, at: now)
        }
    }

    public func relations(of issueRef: String) throws -> [IssueRelation] {
        try writer.read { db in
            let issue = try resolveIssue(db, issueRef)
            return try IssueRelation.filter(Column("issueId") == issue.id).order(Column("createdAt")).fetchAll(db)
        }
    }

    /// True when any open issue blocks this one.
    public func isBlocked(_ issueRef: String) throws -> Bool {
        try writer.read { db in
            let issue = try resolveIssue(db, issueRef)
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM issueRelation
                    JOIN issue blocker ON blocker.id = issueRelation.relatedIssueId
                    JOIN workflowState ON workflowState.id = blocker.stateId
                    WHERE issueRelation.issueId = ? AND issueRelation.type = ?
                      AND workflowState.category NOT IN (?, ?) AND blocker.archivedAt IS NULL
                )
                """, arguments: [issue.id, RelationType.blockedBy.rawValue, StateCategory.completed.rawValue, StateCategory.canceled.rawValue]) ?? false
        }
    }

    // MARK: - Comments

    static let maxCommentLength = 100_000

    @discardableResult
    public func addComment(to issueRef: String, body: String, replyingTo parentId: String? = nil, by memberId: String) throws -> Comment {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw TrackaroError.invalid(field: "body", message: "A comment needs text.") }
        guard body.count <= Self.maxCommentLength else {
            throw TrackaroError.invalid(field: "body", message: "Keep comments under \(Self.maxCommentLength) characters.")
        }
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            let issue = try resolveIssue(db, issueRef)
            if let parentId {
                guard let parent = try Comment.fetchOne(db, key: parentId), parent.issueId == issue.id else {
                    throw TrackaroError.notFound(entity: "comment", reference: parentId)
                }
            }
            let comment = Comment(id: newId(), issueId: issue.id, authorId: memberId, parentId: parentId, body: body, createdAt: now, editedAt: nil, deletedAt: nil)
            try comment.insert(db)
            try recordChange(db, model: "comment", id: comment.id, action: .insert, by: memberId, at: now, snapshot: comment)
            return comment
        }
    }

    /// Comments oldest first, deleted ones excluded.
    public func comments(on issueRef: String) throws -> [Comment] {
        try writer.read { db in
            let issue = try resolveIssue(db, issueRef)
            return try Comment
                .filter(Column("issueId") == issue.id && Column("deletedAt") == nil)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db)
        }
    }

    // MARK: - Search

    /// Full-text search over identifier, title and description. Every word is matched as a prefix, so
    /// "auth tok" finds "Authentication token refresh". An exact identifier match always ranks first.
    public func searchIssues(_ text: String, limit: Int = 20, includeArchived: Bool = false) throws -> [Issue] {
        guard let pattern = Self.ftsPattern(text) else { return [] }
        return try writer.read { db in
            var results: [Issue] = []
            if IssueKey(text) != nil, let exact = try? resolveIssue(db, text), includeArchived || exact.archivedAt == nil {
                results.append(exact)
            }
            let matches = try Issue.fetchAll(db, sql: """
                SELECT issue.* FROM issueSearch
                JOIN issue ON issue.seq = issueSearch.rowid
                WHERE issueSearch MATCH ? AND (issue.archivedAt IS NULL OR ?)
                ORDER BY bm25(issueSearch, 10.0, 5.0, 1.0), issue.updatedAt DESC
                LIMIT ?
                """, arguments: [pattern, includeArchived, limit])
            for match in matches where !results.contains(where: { $0.id == match.id }) {
                results.append(match)
            }
            return Array(results.prefix(limit))
        }
    }
}
