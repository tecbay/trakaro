import Foundation
import GRDB

/// Saved views: a named filter and layout over every team's issues. Names are unique ignoring case, so an agent
/// can refer to a view by name.
extension TrackaroStore {
    public func views() throws -> [SavedView] {
        try writer.read { db in try SavedView.order(Column("sortKey")).fetchAll(db) }
    }

    /// A view by id or by name, ignoring case.
    public func view(_ reference: String) throws -> SavedView {
        try writer.read { db in try resolveView(db, reference) }
    }

    @discardableResult
    public func createView(name: String, filter: IssueFilter, layout: ViewLayout = .list, by memberId: String) throws -> SavedView {
        let name = try Self.viewName(name)
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            try requireUniqueViewName(db, name, except: nil)
            let last = try String.fetchOne(db, sql: "SELECT MAX(sortKey) FROM savedView")
            let view = SavedView(
                id: newId(), name: name, filter: filter.json, layout: layout, groupBy: nil,
                sortKey: try sortKey(between: last, and: nil), createdAt: now, updatedAt: now
            )
            try view.insert(db)
            try recordChange(db, model: "savedView", id: view.id, action: .insert, by: memberId, at: now, snapshot: view)
            return view
        }
    }

    /// Changes the fields that are passed; nil keeps the current value.
    @discardableResult
    public func updateView(
        _ reference: String, name: String? = nil, filter: IssueFilter? = nil, layout: ViewLayout? = nil, by memberId: String
    ) throws -> SavedView {
        let name = try name.map(Self.viewName)
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            var view = try resolveView(db, reference)
            if let name {
                try requireUniqueViewName(db, name, except: view.id)
                view.name = name
            }
            if let filter { view.filter = filter.json }
            if let layout { view.layout = layout }
            view.updatedAt = now
            try view.update(db)
            try recordChange(db, model: "savedView", id: view.id, action: .update, by: memberId, at: now, snapshot: view)
            return view
        }
    }

    public func deleteView(_ reference: String, by memberId: String) throws {
        try writer.write { db in
            _ = try requireMember(db, memberId)
            let view = try resolveView(db, reference)
            try view.delete(db)
            try recordChange(db, model: "savedView", id: view.id, action: .delete, by: memberId, at: clock(), snapshot: SavedView?.none)
        }
    }

    private static func viewName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TrackaroError.invalid(field: "name", message: "A view needs a name.") }
        guard trimmed.count <= 80 else { throw TrackaroError.invalid(field: "name", message: "Keep view names to 80 characters.") }
        return trimmed
    }

    private func resolveView(_ db: Database, _ reference: String) throws -> SavedView {
        if let view = try SavedView.fetchOne(db, key: reference) { return view }
        let all = try SavedView.order(Column("sortKey")).fetchAll(db)
        let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let view = all.first(where: { $0.name.lowercased() == wanted }) { return view }
        throw TrackaroError.noMatch(entity: "view", reference: reference, options: all.map(\.name))
    }

    private func requireUniqueViewName(_ db: Database, _ name: String, except id: String?) throws {
        let clash = try SavedView.fetchAll(db).first { $0.name.lowercased() == name.lowercased() && $0.id != id }
        if let clash {
            throw TrackaroError.conflict(message: "A view named \(clash.name) already exists.", candidates: [clash.name])
        }
    }
}
