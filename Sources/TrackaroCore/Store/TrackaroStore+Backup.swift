import Foundation
import GRDB

/// The automatic copies kept in a `Backups` folder next to the database.
public struct BackupFolder: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case manual
        case daily
        case beforeUpgrade = "before-upgrade"
        case beforeRestore = "before-restore"

        /// How many copies of this kind to keep. Manual backups are the user's and are never removed.
        var kept: Int? {
            switch self {
            case .manual: nil
            case .daily: 7
            case .beforeUpgrade, .beforeRestore: 5
            }
        }

        public var title: String {
            switch self {
            case .manual: "Manual"
            case .daily: "Daily"
            case .beforeUpgrade: "Before an upgrade"
            case .beforeRestore: "Before a restore"
            }
        }
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        public let url: URL
        public let kind: Kind
        public let createdAt: Date
        public let byteCount: Int
        public var id: URL { url }
    }

    public let url: URL

    public init(database: URL) {
        url = database.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    public func newURL(_ kind: Kind, at date: Date) -> URL {
        url.appendingPathComponent("\(Self.fileName(kind, at: date)) \(UUID().uuidString.prefix(4)).sqlite")
    }

    /// Newest first. Files this folder did not name are ignored.
    public func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let entries = files.compactMap { file -> Entry? in
            guard file.pathExtension == "sqlite", let (kind, date) = Self.parse(file.lastPathComponent) else { return nil }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Entry(url: file, kind: kind, createdAt: date, byteCount: size)
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Removes the oldest copies of a kind beyond how many it keeps.
    public func prune(_ kind: Kind) throws {
        guard let kept = kind.kept else { return }
        for entry in entries().filter({ $0.kind == kind }).dropFirst(kept) {
            try FileManager.default.removeItem(at: entry.url)
        }
    }

    private static func fileName(_ kind: Kind, at date: Date) -> String {
        "Trackaro \(kind.rawValue) \(formatter().string(from: date))"
    }

    private static func parse(_ name: String) -> (Kind, Date)? {
        let parts = name.split(separator: " ")
        guard parts.count >= 4, parts[0] == "Trackaro", let kind = Kind(rawValue: String(parts[1])),
              let date = formatter().date(from: "\(parts[2]) \(parts[3].prefix(8))") else { return nil }
        return (kind, date)
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }
}

/// What a restore brought back, for telling the user.
public struct RestoreResult: Equatable, Sendable {
    /// The copy of the replaced data, so a restore can itself be undone.
    public let safetyCopy: URL
    public let issueCount: Int
    public let artifactCount: Int
}

extension TrackaroStore {
    /// A consistent copy of the whole database in one file, taken with SQLite's backup API, so it is safe while
    /// agents are writing. A failed copy leaves nothing at `url`.
    public func backup(to url: URL) throws {
        try Self.copyDatabase(from: writer, to: url)
    }

    static func copyDatabase(from source: any DatabaseReader, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { removeDatabaseFiles(at: partial) }
        let destination = try DatabaseQueue(path: partial.path)
        try source.backup(to: destination)
        // Folds the destination into a plain file, so the backup is one file with nothing beside it.
        try destination.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
        }
        try destination.close()
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try fileManager.moveItem(at: partial, to: url)
    }

    /// Makes a daily copy when the newest one is a day old or more. Returns its location if it made one.
    @discardableResult
    public func backupIfDue(in folder: BackupFolder, now: Date = Date(), interval: TimeInterval = 24 * 60 * 60) throws -> URL? {
        if let latest = folder.entries().first(where: { $0.kind == .daily }), now.timeIntervalSince(latest.createdAt) < interval {
            return nil
        }
        let url = folder.newURL(.daily, at: now)
        try backup(to: url)
        try folder.prune(.daily)
        return url
    }

    /// Replaces everything with the contents of a backup, keeping a copy of what was there first.
    ///
    /// The file is never swapped on disk. Every `trackaro-mcp` holds the database open, and a swapped file would
    /// leave them writing to a deleted one. SQLite's backup API writes through the same locks they use, so they see
    /// the restored data on their next read. The backup is checked and upgraded in a private copy first, so a bad
    /// file changes nothing.
    @discardableResult
    public func restore(from url: URL, safetyCopy: URL) throws -> RestoreResult {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("trackaro-restore-\(UUID().uuidString).sqlite")
        defer { Self.removeDatabaseFiles(at: work) }
        try FileManager.default.copyItem(at: url, to: work)

        let incoming = try Self.openBackup(at: work, named: url.lastPathComponent)
        let result = try incoming.write { db -> (issues: Int, artifacts: Int) in
            // A running agent keeps writing as the member it already is, so it must still exist after the restore.
            let current = try writer.read { try Member.filter(Column("kind") == MemberKind.agent.rawValue).fetchAll($0) }
            for member in current where try !member.exists(db) {
                try member.insert(db)
            }
            // Everything in the backup is history, not news. See `feed(after:)`.
            try db.execute(sql: """
                INSERT OR REPLACE INTO restorePoint (id, activity, comment, restoredAt)
                VALUES (1, (SELECT COALESCE(MAX(rowid), 0) FROM issueActivity), (SELECT COALESCE(MAX(rowid), 0) FROM comment), ?)
                """, arguments: [clock()])
            var entry = ChangeEntry(seq: nil, model: "database", modelId: "restore", action: .update, memberId: nil, at: clock(), payload: nil)
            try entry.insert(db)
            return (
                try Issue.filter(Column("archivedAt") == nil).fetchCount(db),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact WHERE deletedAt IS NULL") ?? 0
            )
        }

        try backup(to: safetyCopy)
        try incoming.backup(to: writer)
        try incoming.close()
        return RestoreResult(safetyCopy: safetyCopy, issueCount: result.issues, artifactCount: result.artifacts)
    }

    /// Opens a private copy of a backup, refusing anything that is not a healthy Trackaro database this version
    /// understands, and brings it up to the current schema.
    private static func openBackup(at url: URL, named name: String) throws -> DatabaseQueue {
        func refuse(_ message: String) -> TrackaroError { .invalid(field: "backup", message: "\(name) \(message)") }

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: configuration())
            let healthy = try queue.read { db -> Bool in
                try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok"
                    && db.tableExists("grdb_migrations") && db.tableExists("issue") && db.tableExists("member")
            }
            guard healthy else { throw refuse("is not a Trackaro backup, or it is damaged.") }
        } catch let error as TrackaroError {
            throw error
        } catch {
            throw refuse("is not a Trackaro backup, or it is damaged.")
        }

        let unknown = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")).subtracting(Schema.migrator.migrations)
        }
        guard unknown.isEmpty else {
            throw refuse("was made by a newer version of Trackaro. Update Trackaro, then restore it again.")
        }
        try Schema.migrator.migrate(queue)
        return queue
    }

    private static func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
