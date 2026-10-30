import Foundation
import GRDB

/// A position in the change feed: the last issue activity row and the last comment row already seen.
/// Written as `activity:comment`, so hooks and scripts can keep it in a file.
public struct FeedCursor: Hashable, Sendable, CustomStringConvertible {
    public var activity: Int64
    public var comment: Int64

    public init(activity: Int64, comment: Int64) {
        self.activity = activity
        self.comment = comment
    }

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2, let activity = Int64(parts[0]), let comment = Int64(parts[1]) else { return nil }
        self.init(activity: activity, comment: comment)
    }

    public var description: String { "\(activity):\(comment)" }
}

/// One thing that happened to an issue: a field change or a comment, with who did it.
public struct FeedEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case activity(IssueActivity)
        case comment(Comment)
    }

    public let kind: Kind
    public let issue: Issue
    public let member: Member
    public let at: Date
}

extension TrackaroStore {
    /// The cursor just past everything recorded so far. Start here to see only what happens next.
    public func feedHead() throws -> FeedCursor {
        try writer.read { db in
            FeedCursor(
                activity: try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM issueActivity") ?? 0,
                comment: try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM comment") ?? 0
            )
        }
    }

    /// Events after `cursor`, oldest first, and the cursor to pass next time.
    ///
    /// Filtered-out events still advance the cursor, so they are skipped rather than returned later.
    /// `memberKinds` keeps only events by those kinds of member (for example `[.user]` for what the human did);
    /// `excludingMember` drops one member's own events, so an agent is not told about its own changes.
    public func feed(
        after cursor: FeedCursor, memberKinds: Set<MemberKind>? = nil, excludingMember: String? = nil, limit: Int = 200
    ) throws -> (events: [FeedEvent], cursor: FeedCursor) {
        try writer.read { db in
            let activityRows = try Row.fetchAll(db, sql: "SELECT rowid AS feedRow, * FROM issueActivity WHERE rowid > ? ORDER BY rowid LIMIT ?",
                                                arguments: [cursor.activity, limit])
            let commentRows = try Row.fetchAll(db, sql: "SELECT rowid AS feedRow, * FROM comment WHERE rowid > ? AND deletedAt IS NULL ORDER BY rowid LIMIT ?",
                                               arguments: [cursor.comment, limit])
            var next = cursor
            var events: [(FeedEvent, Int64)] = []
            let members = Dictionary(uniqueKeysWithValues: try Member.fetchAll(db).map { ($0.id, $0) })
            var issues: [String: Issue] = [:]
            func issue(_ id: String) throws -> Issue? {
                if let cached = issues[id] { return cached }
                let fetched = try Issue.filter(Column("id") == id).fetchOne(db)
                issues[id] = fetched
                return fetched
            }
            func keep(_ member: Member) -> Bool {
                (memberKinds?.contains(member.kind) ?? true) && member.id != excludingMember
            }

            for row in activityRows {
                let rowNumber: Int64 = row["feedRow"]
                next.activity = max(next.activity, rowNumber)
                let activity = try IssueActivity(row: row)
                guard let member = members[activity.memberId], keep(member), let subject = try issue(activity.issueId) else { continue }
                events.append((FeedEvent(kind: .activity(activity), issue: subject, member: member, at: activity.createdAt), rowNumber))
            }
            for row in commentRows {
                let rowNumber: Int64 = row["feedRow"]
                next.comment = max(next.comment, rowNumber)
                let comment = try Comment(row: row)
                guard let member = members[comment.authorId], keep(member), let subject = try issue(comment.issueId) else { continue }
                events.append((FeedEvent(kind: .comment(comment), issue: subject, member: member, at: comment.createdAt), rowNumber))
            }
            let ordered = events.sorted { ($0.0.at, $0.1) < ($1.0.at, $1.1) }.map(\.0)
            return (ordered, next)
        }
    }
}
