import Foundation
import MCP
import TrackaroCore

/// Shared-resource locks for chats working in parallel: QA lanes, a repository's merge step. Trackaro owns them, so
/// taking a lock is atomic, waiters are served in order and told when it is their turn, and a lock whose chat went
/// quiet or closed is freed. Each tool acts for this chat unless `session_id` names another.
enum LockTools {
    static var all: [ToolDefinition] {
        [acquireLock, releaseLock, heartbeatLock, lockStatus, leaveQueue, releaseAllForSession]
    }

    private static let sessionProperty = JSONSchema.string("The chat's session id. Omit for this chat, which is almost always right.")

    static let acquireLock = ToolDefinition(
        name: "acquire_lock",
        title: "Acquire lock",
        description: """
            Take a shared resource, such as qa-web or "merge mobicart-be", before using it. Returns status "granted" when \
            it is yours now, or "queued" with your position and who holds it. When queued, do not use the resource: \
            this chat is told when it becomes yours. Asking again returns where you stand. While holding it, call \
            heartbeat_lock at least every few minutes, and release_lock when done.
            """,
        inputSchema: JSONSchema.object([
            "resource": JSONSchema.string("Lock name. lock_status lists them."),
            "task": JSONSchema.string("The issue this work is for, such as ENG-71. Its history records the lock."),
            "note": JSONSchema.string("What you will do with it, shown to the user and to chats waiting behind you."),
            "session_title": JSONSchema.string("A short name for this chat, shown in the Locks page and on the issue."),
            "ttl_seconds": JSONSchema.integer("Seconds without a heartbeat before the lock is taken back. Default 900.",
                                              minimum: TrackaroStore.lockTTLRange.lowerBound, maximum: TrackaroStore.lockTTLRange.upperBound),
            "session_id": sessionProperty,
        ], required: ["resource", "task"]),
        readOnly: false
    ) { context, arguments in
        let request = LockRequest(
            resource: try arguments.requiredString("resource"), issue: try arguments.requiredString("task"),
            sessionId: try sessionId(arguments, context), sessionTitle: try arguments.string("session_title"),
            note: try arguments.string("note"), processId: try ownSession(arguments, context) ? context.processId : nil,
            ttlSeconds: try arguments.int("ttl_seconds") ?? TrackaroStore.defaultLockTTL
        )
        let result = try context.store.acquireLock(request)
        let now = Date()
        var object = ObjectBuilder()
        switch result {
        case let .granted(hold):
            object.set("status", "granted")
            object.set("resource", hold.resource)
            object.set("task", try identifier(hold.issueId, context))
            object.set("expires_in_seconds", Int(hold.expiresAt.timeIntervalSince(now).rounded()))
            object.set("next", "Call heartbeat_lock during long work and release_lock with a result note when done.")
        case let .queued(waiter, position, blockedBy):
            object.set("status", "queued")
            object.set("resource", waiter.resource)
            object.set("task", try identifier(waiter.issueId, context))
            object.set("position", position)
            object.set("held_by", .array(try blockedBy.map { try holder($0, context, now: now).value }))
            object.set("next", "Do not use the resource yet. This chat is told when the lock is granted; leave_queue stops waiting.")
        }
        return object.value
    }

    static let releaseLock = ToolDefinition(
        name: "release_lock",
        title: "Release lock",
        description: "Let go of a lock this chat holds. The next chat in the queue gets it and is told, along with your result note.",
        inputSchema: JSONSchema.object([
            "resource": JSONSchema.string("Lock name."),
            "result_note": JSONSchema.string("How it went, such as \"QA passed on build 412\". Passed to whoever is next."),
            "session_id": sessionProperty,
        ], required: ["resource"]),
        readOnly: false
    ) { context, arguments in
        let resource = try arguments.requiredString("resource")
        let granted = try context.store.releaseLock(resource, sessionId: try sessionId(arguments, context), resultNote: try arguments.string("result_note"))
        var object = ObjectBuilder()
        object.set("released", resource)
        object.set("granted_to", .array(try granted.map { try holder($0, context, now: Date()).value }))
        return object.value
    }

    static let heartbeatLock = ToolDefinition(
        name: "heartbeat_lock",
        title: "Heartbeat lock",
        description: "Keep a held lock from expiring during long work such as a QA run or a build. Call it every few minutes.",
        inputSchema: JSONSchema.object([
            "resource": JSONSchema.string("Lock name."),
            "session_id": sessionProperty,
        ], required: ["resource"]),
        readOnly: false
    ) { context, arguments in
        let own = try ownSession(arguments, context)
        let hold = try context.store.heartbeatLock(try arguments.requiredString("resource"), sessionId: try sessionId(arguments, context),
                                                   processId: own ? context.processId : nil)
        return [
            "resource": .string(hold.resource),
            "expires_in_seconds": .int(Int(hold.expiresAt.timeIntervalSinceNow.rounded())),
        ]
    }

    static let lockStatus = ToolDefinition(
        name: "lock_status",
        title: "Lock status",
        description: "Who holds each lock, who is waiting in order, and for how long. Entries for this chat say \"you\": true.",
        inputSchema: JSONSchema.object([
            "resource": JSONSchema.string("One lock. Omit for every lock."),
        ]),
        readOnly: true
    ) { context, arguments in
        let now = Date()
        let states = try context.store.lockStates(resource: try arguments.string("resource"))
        return ["locks": .array(try states.map { state in
            var object = ObjectBuilder()
            object.set("resource", state.resource)
            object.set("conflicts_with", .array(state.conflictsWith.map(Value.string)))
            if let hold = state.holder {
                object.set("holder", try holder(hold, context, now: now).value)
            } else {
                object.set("free", true)
            }
            object.set("queue", .array(try state.queue.enumerated().map { index, waiter in
                var entry = ObjectBuilder()
                entry.set("position", index + 1)
                entry.set("task", try identifier(waiter.issueId, context))
                entry.set("chat", waiter.sessionTitle)
                entry.set("session_id", waiter.sessionId)
                entry.set("note", waiter.note)
                entry.set("waiting", TrackaroStore.duration(now.timeIntervalSince(waiter.enqueuedAt)))
                if waiter.sessionId == context.sessionId { entry.set("you", true) }
                return entry.value
            }))
            return object.value
        })]
    }

    static let leaveQueue = ToolDefinition(
        name: "leave_queue",
        title: "Leave lock queue",
        description: "Stop waiting for a lock.",
        inputSchema: JSONSchema.object([
            "resource": JSONSchema.string("Lock name."),
            "session_id": sessionProperty,
        ], required: ["resource"]),
        readOnly: false
    ) { context, arguments in
        let resource = try arguments.requiredString("resource")
        let granted = try context.store.leaveLockQueue(resource, sessionId: try sessionId(arguments, context))
        var object = ObjectBuilder()
        object.set("left", resource)
        object.set("granted_to", .array(try granted.map { try holder($0, context, now: Date()).value }))
        return object.value
    }

    static let releaseAllForSession = ToolDefinition(
        name: "release_all_for_session",
        title: "Release all locks for a chat",
        description: """
            Release every lock a chat holds and take it out of every queue, as when the chat ends. A SessionEnd hook \
            running `trackaro-mcp release-session` does this without a tool call.
            """,
        inputSchema: JSONSchema.object([
            "session_id": sessionProperty,
        ]),
        readOnly: false,
        destructive: true
    ) { context, arguments in
        let result = try context.store.releaseLocks(forSession: try sessionId(arguments, context))
        var object = ObjectBuilder()
        object.set("released", .array(result.released.map(Value.string)))
        object.set("left_queues", .array(result.left.map(Value.string)))
        object.set("granted_to", .array(try result.granted.map { try holder($0, context, now: Date()).value }))
        if result.released.isEmpty && result.left.isEmpty { object.set("note", "This chat held no locks and waited for none.") }
        return object.value
    }

    // MARK: - Channel events

    /// The text pushed into a chat for an event addressed to it. Information only: what changed and which lock tools
    /// apply. Notes written by other chats are quoted as theirs, never as instructions.
    static func message(for event: LockEvent, store: TrackaroStore) -> (content: String, meta: [String: String])? {
        let task = (try? store.issue(event.issueId).identifier) ?? "its task"
        let ttl = (try? store.lockStates(resource: event.resource).first?.holder).flatMap { $0 }
        var meta = ["source": "trackaro", "resource": event.resource, "issue": task]
        let content: String
        switch event.kind {
        case .granted:
            meta["kind"] = "lock_granted"
            let minutes = (ttl?.ttlSeconds ?? TrackaroStore.defaultLockTTL) / 60
            var lines = ["Lock \(event.resource) is now held by this chat, for \(task)."]
            if let note = event.detail { lines.append("The previous holder's result note: “\(note)”") }
            lines.append("Call heartbeat_lock during long work (it expires after \(minutes) min without one) and release_lock with a result note when done.")
            content = lines.joined(separator: " ")
        case .expired:
            meta["kind"] = "lock_expired"
            content = "Lock \(event.resource) is no longer held by this chat (\(task)). \(event.detail ?? "") Another chat may hold it now; acquire_lock asks for it again."
        case .forceReleased:
            meta["kind"] = "lock_force_released"
            content = "Lock \(event.resource) was taken back from this chat (\(task)). \(event.detail ?? "") Another chat may hold it now; acquire_lock asks for it again."
        case .acquired, .queued, .released, .leftQueue:
            return nil
        }
        return (content, meta)
    }

    // MARK: - Helpers

    private static func sessionId(_ arguments: Arguments, _ context: ToolContext) throws -> String {
        try arguments.string("session_id") ?? context.sessionId
    }

    /// True when the call is about this chat, so this process can be recorded as the one serving it.
    private static func ownSession(_ arguments: Arguments, _ context: ToolContext) throws -> Bool {
        try sessionId(arguments, context) == context.sessionId
    }

    private static func identifier(_ issueId: String, _ context: ToolContext) throws -> String {
        try context.store.issue(issueId).identifier
    }

    private static func holder(_ hold: LockHolder, _ context: ToolContext, now: Date) throws -> ObjectBuilder {
        var object = ObjectBuilder()
        object.set("resource", hold.resource)
        object.set("task", try identifier(hold.issueId, context))
        object.set("chat", hold.sessionTitle)
        object.set("session_id", hold.sessionId)
        object.set("note", hold.note)
        object.set("held_for", TrackaroStore.duration(now.timeIntervalSince(hold.acquiredAt)))
        if hold.acquiredAt.timeIntervalSince(hold.requestedAt) >= 1 {
            object.set("waited", TrackaroStore.duration(hold.acquiredAt.timeIntervalSince(hold.requestedAt)))
        }
        object.set("last_heartbeat", "\(TrackaroStore.duration(now.timeIntervalSince(hold.heartbeatAt))) ago")
        object.set("expires_in", TrackaroStore.duration(hold.expiresAt.timeIntervalSince(now)))
        if hold.sessionId == context.sessionId { object.set("you", true) }
        return object
    }
}
