import Darwin
import Foundation
import GRDB

/// Shared-resource locks for chats working in parallel: one holder per resource, a first-come-first-served queue,
/// conflict rules between resources, and expiry when a holder stops sending heartbeats or its chat goes away.
///
/// Every change runs in one write transaction, which SQLite makes exclusive across the app and every `trackaro-mcp`
/// process, so two chats can never both take a free lock. Each change also writes a `lockEvent` row, addressed to a
/// chat when it should hear about it, and a comment on the task's issue so its history shows the whole story.
extension TrackaroStore {
    /// How long a lock lasts without a heartbeat, unless the caller asks for another time.
    public static let defaultLockTTL = 900
    public static let lockTTLRange = 60...86_400

    // MARK: - Reads

    public func lockResources() throws -> [LockResource] {
        try writer.read { db in try LockResource.order(Column("name").collating(.nocase)).fetchAll(db) }
    }

    /// Every resource, or one, with its holder and queue in order.
    public func lockStates(resource: String? = nil) throws -> [LockState] {
        try writer.read { db in
            let names = try resource.map { [try resolveLockResource(db, $0)] }
                ?? String.fetchAll(db, sql: "SELECT name FROM lockResource ORDER BY name COLLATE NOCASE")
            let table = try LockTable(db)
            return names.map { name in
                LockState(
                    resource: name,
                    conflictsWith: table.conflicts(of: name),
                    holder: table.holds.first { $0.resource == name },
                    queue: table.queue.filter { $0.resource == name }
                )
            }
        }
    }

    /// The locks each issue holds or waits for, for badges in lists.
    public func issueLockBadges() throws -> [String: IssueLockBadge] {
        try writer.read { db in
            var badges: [String: IssueLockBadge] = [:]
            for hold in try LockHolder.order(Column("resource")).fetchAll(db) {
                badges[hold.issueId, default: IssueLockBadge()].held.append(hold.resource)
            }
            for waiter in try LockWaiter.order(Column("id")).fetchAll(db) {
                badges[waiter.issueId, default: IssueLockBadge()].waiting.append(waiter.resource)
            }
            return badges
        }
    }

    /// The newest lock event. A chat's server starts reading after this, so it is only told what happens next.
    public func lockEventHead() throws -> Int64 {
        try writer.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM lockEvent") ?? 0 }
    }

    /// Events addressed to one chat after `id`, oldest first. No other chat's events are ever returned.
    public func lockEvents(after id: Int64, for sessionId: String, limit: Int = 50) throws -> [LockEvent] {
        try writer.read { db in
            try LockEvent
                .filter(Column("targetSessionId") == sessionId && Column("id") > id)
                .order(Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Recent history of one resource, or all of them, newest first.
    public func lockHistory(resource: String? = nil, limit: Int = 100) throws -> [LockEvent] {
        try writer.read { db in
            var request = LockEvent.order(Column("id").desc).limit(limit)
            if let resource { request = request.filter(Column("resource") == (try resolveLockResource(db, resource))) }
            return try request.fetchAll(db)
        }
    }

    // MARK: - Chats

    /// Takes the lock if it is free and nothing conflicting is held or waited for ahead of this chat; otherwise
    /// joins the queue. Asking again from the same chat returns where it already stands.
    public func acquireLock(_ request: LockRequest) throws -> LockAcquisition {
        let sessionId = try Self.sessionId(request.sessionId)
        guard Self.lockTTLRange.contains(request.ttlSeconds) else {
            throw TrackaroError.invalid(field: "ttl_seconds", message: "Use \(Self.lockTTLRange.lowerBound) to \(Self.lockTTLRange.upperBound) seconds.")
        }
        return try writer.write { db in
            let now = clock()
            let name = try resolveLockResource(db, request.resource)
            let issue = try resolveIssue(db, request.issue)
            let title = Self.trimmed(request.sessionTitle)
            let note = Self.trimmed(request.note)
            if let processId = request.processId { try adopt(db, sessionId: sessionId, processId: processId) }
            var table = try LockTable(db)

            if var hold = table.holds.first(where: { $0.resource == name && $0.sessionId == sessionId }) {
                hold.heartbeatAt = now
                try hold.update(db)
                return .granted(hold)
            }
            if let waiter = table.queue.first(where: { $0.resource == name && $0.sessionId == sessionId }) {
                return table.queued(waiter)
            }

            if table.isFree(name) {
                let hold = LockHolder(
                    resource: name, issueId: issue.id, sessionId: sessionId, sessionTitle: title, note: note,
                    processId: request.processId, ttlSeconds: request.ttlSeconds, requestedAt: now, acquiredAt: now, heartbeatAt: now
                )
                try hold.insert(db)
                try logLock(db, .acquired, resource: name, issueId: issue.id, sessionId: sessionId, title: title, note: note, at: now)
                try lockComment(db, issue: issue, "Lock \(name) granted to \(issue.identifier) (\(Self.chat(title, sessionId))).", at: now)
                return .granted(hold)
            }

            var waiter = LockWaiter(
                id: nil, resource: name, issueId: issue.id, sessionId: sessionId, sessionTitle: title, note: note,
                processId: request.processId, ttlSeconds: request.ttlSeconds, enqueuedAt: now
            )
            try waiter.insert(db)
            table.queue.append(waiter)
            let result = table.queued(waiter)
            try logLock(db, .queued, resource: name, issueId: issue.id, sessionId: sessionId, title: title, note: note, at: now)
            if case let .queued(_, position, blockedBy) = result {
                let holders = try blockedBy.map { try describe(db, $0) }.joined(separator: ", ")
                let behind = holders.isEmpty ? "" : " Held by \(holders)."
                try lockComment(db, issue: issue, "\(issue.identifier) (\(Self.chat(title, sessionId))) is waiting for lock \(name), position \(position).\(behind)", at: now)
            }
            return result
        }
    }

    /// Lets go of a lock and hands it to whoever is next. Only the holder can release. Returns the locks granted.
    @discardableResult
    public func releaseLock(_ resource: String, sessionId: String, resultNote: String? = nil) throws -> [LockHolder] {
        let sessionId = try Self.sessionId(sessionId)
        return try writer.write { db in
            let now = clock()
            let name = try resolveLockResource(db, resource)
            let hold = try requireHolder(db, name, sessionId: sessionId)
            let note = Self.trimmed(resultNote)
            try hold.delete(db)
            try logLock(db, .released, resource: name, issueId: hold.issueId, sessionId: sessionId, title: hold.sessionTitle, note: note, at: now)
            let held = Self.duration(now.timeIntervalSince(hold.acquiredAt))
            try lockComment(db, issueId: hold.issueId, "Lock \(name) released by \(try identifier(db, hold.issueId)) (\(Self.chat(hold.sessionTitle, sessionId))) after \(held).\(note.map { " Result: \($0)" } ?? "")", at: now)
            return try promote(db, at: now, notes: [name: note])
        }
    }

    /// Pushes back a held lock's expiry. Chats call this during long runs.
    @discardableResult
    public func heartbeatLock(_ resource: String, sessionId: String, processId: Int? = nil) throws -> LockHolder {
        let sessionId = try Self.sessionId(sessionId)
        return try writer.write { db in
            let name = try resolveLockResource(db, resource)
            if let processId { try adopt(db, sessionId: sessionId, processId: processId) }
            var hold = try requireHolder(db, name, sessionId: sessionId)
            hold.heartbeatAt = clock()
            try hold.update(db)
            return hold
        }
    }

    /// Stops waiting for a lock. Returns any locks this frees up for others.
    @discardableResult
    public func leaveLockQueue(_ resource: String, sessionId: String) throws -> [LockHolder] {
        let sessionId = try Self.sessionId(sessionId)
        return try writer.write { db in
            let now = clock()
            let name = try resolveLockResource(db, resource)
            guard let waiter = try LockWaiter.filter(Column("resource") == name && Column("sessionId") == sessionId).fetchOne(db) else {
                throw TrackaroError.invalid(field: "resource", message: "This chat is not waiting for \(name).")
            }
            try removeWaiter(db, waiter, reason: nil, at: now)
            return try promote(db, at: now, notes: [:])
        }
    }

    /// Releases everything a chat holds and takes it out of every queue, as when the chat closes.
    public func releaseLocks(forSession sessionId: String, reason: String = "Its chat ended.") throws -> (released: [String], left: [String], granted: [LockHolder]) {
        let sessionId = try Self.sessionId(sessionId)
        return try writer.write { db in
            let now = clock()
            let holds = try LockHolder.filter(Column("sessionId") == sessionId).fetchAll(db)
            let waiters = try LockWaiter.filter(Column("sessionId") == sessionId).order(Column("id")).fetchAll(db)
            var notes: [String: String?] = [:]
            for hold in holds {
                try hold.delete(db)
                try logLock(db, .released, resource: hold.resource, issueId: hold.issueId, sessionId: sessionId, title: hold.sessionTitle, note: reason, at: now)
                try lockComment(db, issueId: hold.issueId, "Lock \(hold.resource) released by \(try identifier(db, hold.issueId)) (\(Self.chat(hold.sessionTitle, sessionId))): \(reason)", at: now)
                notes[hold.resource] = reason
            }
            for waiter in waiters { try removeWaiter(db, waiter, reason: reason, at: now) }
            let granted = holds.isEmpty && waiters.isEmpty ? [] : try promote(db, at: now, notes: notes)
            return (holds.map(\.resource), waiters.map(\.resource), granted)
        }
    }

    /// Records that a chat is now served by another process, so a reconnected chat does not look dead.
    public func adoptLocks(sessionId: String, processId: Int) throws {
        try writer.write { db in try adopt(db, sessionId: sessionId, processId: processId) }
    }

    // MARK: - The user

    /// Takes a lock away from its holder, for the user when a chat is stuck. The holder is told and the next chat gets it.
    @discardableResult
    public func forceReleaseLock(_ resource: String, by memberId: String) throws -> [LockHolder] {
        try writer.write { db in
            let now = clock()
            let member = try requireMember(db, memberId)
            let name = try resolveLockResource(db, resource)
            guard let hold = try LockHolder.fetchOne(db, key: name) else {
                throw TrackaroError.invalid(field: "resource", message: "Nobody holds \(name).")
            }
            try hold.delete(db)
            try logLock(db, .forceReleased, resource: name, issueId: hold.issueId, sessionId: hold.sessionId, title: hold.sessionTitle,
                        note: hold.note, target: hold.sessionId, detail: "Force-released by \(member.name).", at: now)
            try lockComment(db, issueId: hold.issueId, "Lock \(name) force-released from \(try identifier(db, hold.issueId)) (\(Self.chat(hold.sessionTitle, hold.sessionId))) by \(member.name == "Me" ? "the user" : member.name).", at: now)
            return try promote(db, at: now, notes: [name: nil])
        }
    }

    /// Adds a resource, or adds conflicts to an existing one. Conflicts work in both directions.
    @discardableResult
    public func defineLockResource(_ name: String, conflictsWith others: [String] = []) throws -> LockResource {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else {
            throw TrackaroError.invalid(field: "name", message: "A lock needs a name of up to 100 characters.")
        }
        return try writer.write { db in
            let now = clock()
            let resource: LockResource
            if let existing = try LockResource.filter(sql: "name = ?", arguments: [trimmed]).fetchOne(db) {
                resource = existing
            } else {
                resource = LockResource(name: trimmed, createdAt: now)
                try resource.insert(db)
            }
            for other in others {
                let otherName = try resolveLockResource(db, other)
                guard otherName != resource.name else { continue }
                let exists = try Bool.fetchOne(db, sql: """
                    SELECT 1 FROM lockConflict WHERE (resource = ? AND other = ?) OR (resource = ? AND other = ?)
                    """, arguments: [resource.name, otherName, otherName, resource.name]) ?? false
                if !exists { try LockConflict(resource: resource.name, other: otherName).insert(db) }
            }
            try recordChange(db, model: "lock", id: resource.name, action: .insert, by: nil, at: now, snapshot: resource)
            return resource
        }
    }

    /// Removes a resource nobody holds or waits for.
    public func deleteLockResource(_ name: String) throws {
        try writer.write { db in
            let resolved = try resolveLockResource(db, name)
            let busy = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM lockHold WHERE resource = ?) OR EXISTS (SELECT 1 FROM lockQueue WHERE resource = ?)
                """, arguments: [resolved, resolved]) ?? false
            guard !busy else { throw TrackaroError.invalid(field: "name", message: "\(resolved) is held or has chats waiting. Release it first.") }
            try db.execute(sql: "DELETE FROM lockResource WHERE name = ?", arguments: [resolved])
            try recordChange(db, model: "lock", id: resolved, action: .delete, by: nil, at: clock(), snapshot: LockResource?.none)
        }
    }

    // MARK: - Expiry

    /// Frees locks whose holder has not sent a heartbeat within its time to live or whose process has ended, drops
    /// waiters whose process has ended, and hands the freed locks on. Safe to run from every process at once: the
    /// check is repeated inside the write transaction. Returns the expiry events written.
    @discardableResult
    public func expireLocks(isProcessAlive: (Int) -> Bool = TrackaroStore.processIsAlive) throws -> [LockEvent] {
        let now = clock()
        func expired(_ hold: LockHolder) -> Bool {
            hold.expiresAt < now || hold.processId.map { !isProcessAlive($0) } == true
        }
        func gone(_ waiter: LockWaiter) -> Bool { waiter.processId.map { !isProcessAlive($0) } == true }
        let due = try writer.read { db in
            try LockHolder.fetchAll(db).contains(where: expired) || LockWaiter.fetchAll(db).contains(where: gone)
        }
        guard due else { return [] }
        return try writer.write { db in
            var events: [LockEvent] = []
            var notes: [String: String?] = [:]
            for hold in try LockHolder.fetchAll(db) where expired(hold) {
                let timedOut = hold.expiresAt < now
                let reason = timedOut
                    ? "No heartbeat for \(Self.duration(now.timeIntervalSince(hold.heartbeatAt)))."
                    : "Its chat's Trackaro connection ended."
                try hold.delete(db)
                events.append(try logLock(db, .expired, resource: hold.resource, issueId: hold.issueId, sessionId: hold.sessionId,
                                          title: hold.sessionTitle, note: hold.note, target: hold.sessionId, detail: reason, at: now))
                try lockComment(db, issueId: hold.issueId, "Lock \(hold.resource) expired for \(try identifier(db, hold.issueId)) (\(Self.chat(hold.sessionTitle, hold.sessionId))). \(reason)", at: now)
                notes[hold.resource] = .some(nil)
            }
            for waiter in try LockWaiter.order(Column("id")).fetchAll(db) where gone(waiter) {
                try removeWaiter(db, waiter, reason: "Its chat's Trackaro connection ended.", at: now)
            }
            _ = try promote(db, at: now, notes: notes)
            return events
        }
    }

    /// True while a process with this id exists. Locks are local to this Mac, so its process ids mean something.
    public static func processIsAlive(_ processId: Int) -> Bool {
        guard processId > 0 else { return false }
        return kill(pid_t(processId), 0) == 0 || errno == EPERM
    }

    // MARK: - Helpers

    /// Hands free locks to waiters in the order they joined. A waiter that cannot go yet keeps its place: later
    /// waiters for the same or a conflicting resource stay behind it, so nobody waits forever. `notes` carries the
    /// previous holder's result note for each freed resource, to pass to whoever gets it next.
    private func promote(_ db: Database, at now: Date, notes: [String: String?]) throws -> [LockHolder] {
        var table = try LockTable(db)
        var reserved: [String] = []
        var granted: [LockHolder] = []
        for waiter in table.queue {
            let blocked = table.holds.contains { table.clash($0.resource, waiter.resource) }
                || reserved.contains { table.clash($0, waiter.resource) }
            if blocked {
                reserved.append(waiter.resource)
                continue
            }
            try waiter.delete(db)
            let hold = LockHolder(
                resource: waiter.resource, issueId: waiter.issueId, sessionId: waiter.sessionId, sessionTitle: waiter.sessionTitle,
                note: waiter.note, processId: waiter.processId, ttlSeconds: waiter.ttlSeconds, requestedAt: waiter.enqueuedAt,
                acquiredAt: now, heartbeatAt: now
            )
            try hold.insert(db)
            table.holds.append(hold)
            granted.append(hold)
            let previous = Self.handOverNote(notes, for: waiter.resource, clash: table.clash)
            try logLock(db, .granted, resource: hold.resource, issueId: hold.issueId, sessionId: hold.sessionId, title: hold.sessionTitle,
                        note: hold.note, target: hold.sessionId, detail: previous, at: now)
            let waited = Self.duration(now.timeIntervalSince(waiter.enqueuedAt))
            try lockComment(db, issueId: hold.issueId, "Lock \(hold.resource) granted to \(try identifier(db, hold.issueId)) (\(Self.chat(hold.sessionTitle, hold.sessionId))) after waiting \(waited).", at: now)
        }
        return granted
    }

    /// The result note to pass to whoever gets `resource`: the one left on that lock, or else on a conflicting lock
    /// whose release let this one go, named so the reader knows which run it is about.
    private static func handOverNote(_ notes: [String: String?], for resource: String, clash: (String, String) -> Bool) -> String? {
        if let own = notes[resource] ?? nil { return own }
        for (released, note) in notes.sorted(by: { $0.key < $1.key }) where clash(released, resource) {
            if let note { return "\(released): \(note)" }
        }
        return nil
    }

    private func removeWaiter(_ db: Database, _ waiter: LockWaiter, reason: String?, at now: Date) throws {
        try waiter.delete(db)
        try logLock(db, .leftQueue, resource: waiter.resource, issueId: waiter.issueId, sessionId: waiter.sessionId,
                    title: waiter.sessionTitle, note: waiter.note, detail: reason, at: now)
        let why = reason.map { " \($0)" } ?? ""
        try lockComment(db, issueId: waiter.issueId, "\(try identifier(db, waiter.issueId)) (\(Self.chat(waiter.sessionTitle, waiter.sessionId))) stopped waiting for lock \(waiter.resource).\(why)", at: now)
    }

    private func adopt(_ db: Database, sessionId: String, processId: Int) throws {
        try db.execute(sql: "UPDATE lockHold SET processId = ? WHERE sessionId = ? AND processId IS NOT ?", arguments: [processId, sessionId, processId])
        try db.execute(sql: "UPDATE lockQueue SET processId = ? WHERE sessionId = ? AND processId IS NOT ?", arguments: [processId, sessionId, processId])
    }

    private func requireHolder(_ db: Database, _ name: String, sessionId: String) throws -> LockHolder {
        let hold = try LockHolder.fetchOne(db, key: name)
        if let hold, hold.sessionId == sessionId { return hold }
        let heldBy = try hold.map { " It is held by \(try describe(db, $0))." } ?? ""
        if let waiter = try LockWaiter.filter(Column("resource") == name && Column("sessionId") == sessionId).fetchOne(db),
           case let .queued(_, position, _) = try LockTable(db).queued(waiter) {
            throw TrackaroError.conflict(message: "Only the holder can do that. This chat is still waiting for \(name), at position \(position).\(heldBy) Call leave_queue to stop waiting.", candidates: [])
        }
        if hold != nil {
            throw TrackaroError.conflict(message: "Only the holder can do that.\(heldBy)", candidates: [])
        }
        throw TrackaroError.invalid(field: "resource", message: "This chat does not hold \(name). If it did, it expired or was force-released; call acquire_lock to ask again.")
    }

    func resolveLockResource(_ db: Database, _ reference: String) throws -> String {
        let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = try String.fetchOne(db, sql: "SELECT name FROM lockResource WHERE name = ?", arguments: [wanted]) { return name }
        throw TrackaroError.noMatch(entity: "lock", reference: reference,
                                    options: try String.fetchAll(db, sql: "SELECT name FROM lockResource ORDER BY name COLLATE NOCASE"))
    }

    @discardableResult
    private func logLock(
        _ db: Database, _ kind: LockEventKind, resource: String, issueId: String, sessionId: String, title: String?, note: String?,
        target: String? = nil, detail: String? = nil, at now: Date
    ) throws -> LockEvent {
        var event = LockEvent(id: nil, resource: resource, kind: kind, issueId: issueId, sessionId: sessionId, sessionTitle: title,
                              note: note, targetSessionId: target, detail: detail, at: now)
        try event.insert(db)
        try recordChange(db, model: "lock", id: resource, action: .update, by: nil, at: now, snapshot: event)
        return event
    }

    private func lockComment(_ db: Database, issueId: String, _ body: String, at now: Date) throws {
        guard let issue = try Issue.filter(Column("id") == issueId).fetchOne(db) else { return }
        try lockComment(db, issue: issue, body, at: now)
    }

    /// Lock comments are written by a system member, so the change feed never reports them to chats as the user's.
    private func lockComment(_ db: Database, issue: Issue, _ body: String, at now: Date) throws {
        let author = try lockMember(db, at: now)
        let comment = Comment(id: newId(), issueId: issue.id, authorId: author.id, parentId: nil,
                              body: String(body.prefix(Self.maxCommentLength)), createdAt: now, editedAt: nil, deletedAt: nil)
        try comment.insert(db)
        try recordChange(db, model: "comment", id: comment.id, action: .insert, by: author.id, at: now, snapshot: comment)
    }

    private func lockMember(_ db: Database, at now: Date) throws -> Member {
        if let existing = try Member.filter(Column("kind") == MemberKind.system.rawValue && Column("name") == "Locks").fetchOne(db) {
            return existing
        }
        let member = Member(id: newId(), kind: .system, name: "Locks", clientName: nil, createdAt: now)
        try member.insert(db)
        try recordChange(db, model: "member", id: member.id, action: .insert, by: nil, at: now, snapshot: member)
        return member
    }

    private func identifier(_ db: Database, _ issueId: String) throws -> String {
        try String.fetchOne(db, sql: "SELECT identifier FROM issue WHERE id = ?", arguments: [issueId]) ?? "an issue"
    }

    private func describe(_ db: Database, _ hold: LockHolder) throws -> String {
        "\(try identifier(db, hold.issueId)) (\(Self.chat(hold.sessionTitle, hold.sessionId)))"
    }

    /// How a chat is named in comments: its title when it gave one, else the start of its session id.
    public static func chat(_ title: String?, _ sessionId: String) -> String {
        if let title, !title.isEmpty { return "chat \(title)" }
        return "session \(sessionId.prefix(8))"
    }

    /// "40 s", "12 min", "2 h 5 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    private static func sessionId(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TrackaroError.invalid(field: "session_id", message: "A lock needs the chat's session id.") }
        return trimmed
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(500))
    }
}

/// Holders, the queue and the conflict rules, read once inside a transaction.
private struct LockTable {
    var holds: [LockHolder]
    var queue: [LockWaiter]
    let pairs: Set<[String]>

    init(_ db: Database) throws {
        holds = try LockHolder.fetchAll(db)
        queue = try LockWaiter.order(Column("id")).fetchAll(db)
        pairs = Set(try LockConflict.fetchAll(db).flatMap { [[$0.resource, $0.other], [$0.other, $0.resource]] })
    }

    func clash(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || pairs.contains([lhs, rhs])
    }

    func conflicts(of name: String) -> [String] {
        pairs.filter { $0[0] == name }.map { $0[1] }.sorted()
    }

    /// Free to take now: nothing that clashes is held, and nobody already waits for anything that clashes.
    func isFree(_ name: String) -> Bool {
        !holds.contains { clash($0.resource, name) } && !queue.contains { clash($0.resource, name) }
    }

    func queued(_ waiter: LockWaiter) -> LockAcquisition {
        let same = queue.filter { $0.resource == waiter.resource }
        let position = (same.firstIndex { $0.sessionId == waiter.sessionId } ?? same.count) + 1
        return .queued(waiter, position: position, blockedBy: holds.filter { clash($0.resource, waiter.resource) })
    }
}
