import Foundation
import GRDB

extension TrackaroStore {
    /// The person using this Mac. Created on first call; there is exactly one.
    public func localUser() throws -> Member {
        try writer.write { db in
            if let existing = try Member.filter(Column("kind") == MemberKind.user.rawValue).order(Column("createdAt")).fetchOne(db) {
                return existing
            }
            let member = Member(id: newId(), kind: .user, name: "Me", clientName: nil, createdAt: clock())
            try member.insert(db)
            try recordChange(db, model: "member", id: member.id, action: .insert, by: nil, at: member.createdAt, snapshot: member)
            return member
        }
    }

    /// The member that represents a coding agent. Agents are found by name, so a reconnecting client keeps its history.
    public func agent(named name: String, clientName: String? = nil) throws -> Member {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TrackaroError.invalid(field: "name", message: "An agent needs a name.") }
        return try writer.write { db in
            if var existing = try Member
                .filter(Column("kind") == MemberKind.agent.rawValue)
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [trimmed])
                .fetchOne(db) {
                if let clientName, existing.clientName != clientName {
                    existing.clientName = clientName
                    try existing.update(db)
                }
                return existing
            }
            let member = Member(id: newId(), kind: .agent, name: trimmed, clientName: clientName, createdAt: clock())
            try member.insert(db)
            try recordChange(db, model: "member", id: member.id, action: .insert, by: nil, at: member.createdAt, snapshot: member)
            return member
        }
    }

    public func members() throws -> [Member] {
        try writer.read { db in try Member.order(Column("createdAt")).fetchAll(db) }
    }

    func requireMember(_ db: Database, _ id: String) throws -> Member {
        guard let member = try Member.fetchOne(db, key: id) else {
            throw TrackaroError.notFound(entity: "member", reference: id)
        }
        return member
    }
}
