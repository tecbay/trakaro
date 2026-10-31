import Foundation
import GRDB

/// The single entry point for reading and writing Trackaro data. Every write runs in one transaction that
/// also appends to the change log, so the UI, the MCP server and any future sync see the same history.
public final class TrackaroStore: Sendable {
    public let writer: any DatabaseWriter
    let clock: @Sendable () -> Date

    public init(writer: any DatabaseWriter, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.writer = writer
        self.clock = clock
        do {
            try Schema.migrator.migrate(writer)
        } catch {
            try Schema.migrator.migrate(writer)
        }
    }

    /// Skips migrating, for tests that build a database as an older release left it.
    init(unmigrated writer: any DatabaseWriter) {
        self.writer = writer
        clock = { Date() }
    }

    /// Opens or creates the database file, in WAL mode so readers never block the writer.
    ///
    /// The app and the `trackaro-mcp` process open the same file. SQLite serialises their writes; the busy timeout
    /// makes a writer wait for the other instead of failing. If both create the schema at once, the loser's
    /// migration fails and the retry in `init` finds it already applied.
    public static func open(at url: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws -> TrackaroStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        try backUpBeforeUpgrade(pool, folder: BackupFolder(database: url), now: clock())
        return try TrackaroStore(writer: pool, clock: clock)
    }

    /// Keeps a copy of a database that is about to be migrated, so a bad upgrade can always be undone. A failed copy
    /// stops the upgrade: the data stays as it is rather than changing with no way back. A new database has nothing
    /// to protect.
    private static func backUpBeforeUpgrade(_ pool: DatabasePool, folder: BackupFolder, now: Date) throws {
        let pending = try pool.read { db -> Bool in
            let applied = try Schema.migrator.appliedIdentifiers(db)
            let completed = try Schema.migrator.hasCompletedMigrations(db)
            return !applied.isEmpty && !completed
        }
        guard pending else { return }
        try copyDatabase(from: pool, to: folder.newURL(.beforeUpgrade, at: now))
        try folder.prune(.beforeUpgrade)
    }

    public static func inMemory(clock: @escaping @Sendable () -> Date = { Date() }) throws -> TrackaroStore {
        try TrackaroStore(writer: DatabaseQueue(configuration: configuration()), clock: clock)
    }

    /// The default location: `~/Library/Application Support/Trackaro/trackaro.sqlite`.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Trackaro", isDirectory: true).appendingPathComponent("trackaro.sqlite")
    }

    static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.label = "Trackaro"
        return configuration
    }

    func newId() -> String {
        Identifiers.uuidV7(at: clock())
    }

    // MARK: - Change log

    public func changes(since seq: Int64, limit: Int = 500) throws -> [ChangeEntry] {
        try writer.read { db in
            try ChangeEntry
                .filter(Column("seq") > seq)
                .order(Column("seq"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func latestChangeSeq() throws -> Int64 {
        try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM changeLog") ?? 0
        }
    }

    static let snapshotEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func recordChange<Record: Encodable>(
        _ db: Database, model: String, id: String, action: ChangeAction, by memberId: String?, at: Date, snapshot: Record?
    ) throws {
        let payload = try snapshot.map { String(decoding: try Self.snapshotEncoder.encode($0), as: UTF8.self) }
        var entry = ChangeEntry(seq: nil, model: model, modelId: id, action: action, memberId: memberId, at: at, payload: payload)
        try entry.insert(db)
    }

    func recordActivity(
        _ db: Database, issueId: String, by memberId: String, field: IssueField, from: String?, to: String?, at: Date
    ) throws {
        let activity = IssueActivity(id: newId(), issueId: issueId, memberId: memberId, field: field, fromValue: from, toValue: to, createdAt: at)
        try activity.insert(db)
    }

    /// JSON text for an activity value, or nil when the value is absent.
    static func json<Value: Encodable>(_ value: Value?) -> String? {
        guard let value else { return nil }
        return (try? snapshotEncoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}
