import Foundation
import GRDB

/// Something only one chat can use at a time, such as a QA lane or a repository's merge step.
public struct LockResource: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lockResource"
    public var name: String
    public var createdAt: Date

    public var id: String { name }
}

/// Two resources that cannot be held at once. Stored once per pair; the rule applies in both directions.
public struct LockConflict: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lockConflict"
    public var resource: String
    public var other: String
}

/// Who is using a lock now. A chat is a Claude Code session, named by its session id.
public struct LockHolder: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "lockHold"
    public var resource: String
    public var issueId: String
    public var sessionId: String
    public var sessionTitle: String?
    public var note: String?
    /// The `trackaro-mcp` process serving the chat. When it has ended, the chat is gone and the lock is freed.
    public var processId: Int?
    public var ttlSeconds: Int
    /// When the chat first asked for the lock, which is earlier than `acquiredAt` when it waited in the queue.
    public var requestedAt: Date
    public var acquiredAt: Date
    public var heartbeatAt: Date

    public var expiresAt: Date { heartbeatAt.addingTimeInterval(TimeInterval(ttlSeconds)) }
}

/// A chat waiting for a lock. `id` grows, so ordering by it is first come, first served across every resource.
public struct LockWaiter: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "lockQueue"
    public var id: Int64?
    public var resource: String
    public var issueId: String
    public var sessionId: String
    public var sessionTitle: String?
    public var note: String?
    public var processId: Int?
    public var ttlSeconds: Int
    public var enqueuedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum LockEventKind: String, Codable, CaseIterable, Sendable {
    /// Free when asked for, so held at once.
    case acquired
    case queued
    /// Handed over from the queue after the previous holder let go.
    case granted
    case released
    /// No heartbeat within the time to live, or the chat's process ended.
    case expired
    case forceReleased = "force_released"
    case leftQueue = "left_queue"
}

/// One thing that happened to a lock. `targetSessionId` is set when a chat should be told: the one that was just
/// granted a lock from the queue, or the one that lost it. Each chat's server reads only events addressed to it.
public struct LockEvent: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "lockEvent"
    public var id: Int64?
    public var resource: String
    public var kind: LockEventKind
    public var issueId: String
    public var sessionId: String
    public var sessionTitle: String?
    public var note: String?
    public var targetSessionId: String?
    /// For a grant, the previous holder's result note; for an expiry, why.
    public var detail: String?
    public var at: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A chat asking for a lock.
public struct LockRequest: Sendable {
    public var resource: String
    /// The issue the work is for, by identifier or id. Its history records what happens to the lock.
    public var issue: String
    public var sessionId: String
    public var sessionTitle: String?
    public var note: String?
    public var processId: Int?
    public var ttlSeconds: Int

    public init(resource: String, issue: String, sessionId: String, sessionTitle: String? = nil, note: String? = nil,
                processId: Int? = nil, ttlSeconds: Int = TrackaroStore.defaultLockTTL) {
        self.resource = resource
        self.issue = issue
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.note = note
        self.processId = processId
        self.ttlSeconds = ttlSeconds
    }
}

public enum LockAcquisition: Hashable, Sendable {
    case granted(LockHolder)
    /// `position` counts from 1 among everyone waiting for this resource. `blockedBy` is who holds this resource, or
    /// a conflicting one, right now.
    case queued(LockWaiter, position: Int, blockedBy: [LockHolder])
}

/// One resource as the Locks page and `lock_status` show it.
public struct LockState: Hashable, Sendable, Identifiable {
    public var resource: String
    public var conflictsWith: [String]
    public var holder: LockHolder?
    public var queue: [LockWaiter]

    public var id: String { resource }
}

/// What a lock means for one issue, for the badge in lists.
public struct IssueLockBadge: Hashable, Sendable {
    public var held: [String]
    public var waiting: [String]

    public init(held: [String] = [], waiting: [String] = []) {
        self.held = held
        self.waiting = waiting
    }
}
