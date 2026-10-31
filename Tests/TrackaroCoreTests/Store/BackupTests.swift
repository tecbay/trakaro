import Foundation
import GRDB
import Testing
@testable import TrackaroCore

/// A database file in its own temporary folder, removed afterwards.
private struct TemporaryDatabase {
    let folder: URL
    var url: URL { folder.appendingPathComponent("trackaro.sqlite") }
    var backups: BackupFolder { BackupFolder(database: url) }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("trackaro-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    /// A file holding the schema as 0.1.1 shipped it, with one team and one issue.
    func createAsReleased011() throws {
        let queue = try DatabaseQueue(path: url.path)
        _ = try queue.writeWithoutTransaction { try String.fetchOne($0, sql: "PRAGMA journal_mode = WAL") }
        try Schema.migrator.migrate(queue, upTo: "v2-automations")
        let store = TrackaroStore(unmigrated: queue)
        let me = try store.localUser()
        let team = try store.createTeam(key: "ENG", name: "Engineering", by: me.id)
        _ = try store.createIssue(NewIssue(teamId: team.id, title: "Written by 0.1.1", description: "Keep me"), by: me.id)
        try queue.close()
    }
}

@Suite("Upgrading an existing database")
struct UpgradeTests {
    @Test func openingAReleasedDatabaseKeepsItsDataAndAddsArtifacts() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        try database.createAsReleased011()

        let store = try TrackaroStore.open(at: database.url)

        let issue = try store.issue("ENG-1")
        #expect(issue.title == "Written by 0.1.1")
        #expect(issue.description == "Keep me")
        #expect(try store.searchIssues("Written", limit: 5).map(\.identifier) == ["ENG-1"])
        let me = try store.localUser()
        let project = try store.createProject(name: "Launch", by: me.id)
        try store.saveArtifact(projectId: project.id, name: "spec.md", content: Data("# Spec".utf8), by: me.id)
        #expect(try store.artifacts(projectId: project.id).count == 1)
    }

    @Test func upgradingKeepsAWorkingCopyOfTheOldDatabaseFirst() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        try database.createAsReleased011()

        _ = try TrackaroStore.open(at: database.url)

        let copies = database.backups.entries().filter { $0.kind == .beforeUpgrade }
        #expect(copies.count == 1)
        let copy = try DatabaseQueue(path: try #require(copies.first).url.path)
        let title = try copy.read { try String.fetchOne($0, sql: "SELECT title FROM issue") }
        let hasArtifacts = try copy.read { try $0.tableExists("artifact") }
        #expect(title == "Written by 0.1.1")
        #expect(!hasArtifacts)
    }

    @Test func noCopyWhenThereIsNothingToUpgrade() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }

        _ = try TrackaroStore.open(at: database.url)
        _ = try TrackaroStore.open(at: database.url)

        #expect(database.backups.entries().isEmpty)
    }

    @Test func changesFitTheChecksOldDatabasesAlreadyHave() throws {
        // Upgrades add tables only, so writes by the new code must fit the CHECKs an old database already has.
        #expect(ChangeAction.allCases.map(\.rawValue) == ["insert", "update", "delete", "archive", "unarchive"])
        #expect(IssueField.allCases.count == 17)
    }
}

@Suite("Backup and restore")
struct BackupTests {
    private func filled(_ database: TemporaryDatabase) throws -> (TrackaroStore, Member, Team) {
        let store = try TrackaroStore.open(at: database.url)
        let me = try store.localUser()
        let team = try store.createTeam(key: "ENG", name: "Engineering", by: me.id)
        return (store, me, team)
    }

    @Test func aBackupIsOneFileThatOpensOnItsOwn() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, me, team) = try filled(database)
        _ = try store.createIssue(NewIssue(teamId: team.id, title: "Saved"), by: me.id)
        let target = database.folder.appendingPathComponent("copy.sqlite")

        try store.backup(to: target)

        #expect(!FileManager.default.fileExists(atPath: target.path + "-wal"))
        #expect(try TrackaroStore.open(at: target).issue("ENG-1").title == "Saved")
    }

    @Test func restoreBringsBackDataAndArtifactsAndKeepsASafetyCopy() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, me, team) = try filled(database)
        let project = try store.createProject(name: "Launch", by: me.id)
        try store.saveArtifact(projectId: project.id, name: "spec.md", content: Data("v1".utf8), by: me.id)
        _ = try store.createIssue(NewIssue(teamId: team.id, title: "Before the backup"), by: me.id)
        let backup = database.folder.appendingPathComponent("backup.sqlite")
        try store.backup(to: backup)

        _ = try store.createIssue(NewIssue(teamId: team.id, title: "After the backup"), by: me.id)
        let safety = database.folder.appendingPathComponent("safety.sqlite")
        let result = try store.restore(from: backup, safetyCopy: safety)

        #expect(result.issueCount == 1)
        #expect(result.artifactCount == 1)
        #expect(try store.issues(teamId: team.id).map(\.title) == ["Before the backup"])
        #expect(try store.searchIssues("after", limit: 5).isEmpty)
        #expect(try store.artifact("spec.md").text == "v1")
        #expect(try TrackaroStore.open(at: safety).issue("ENG-2").title == "After the backup")
    }

    @Test func aSecondConnectionSeesTheRestoreAndCanStillWrite() throws {
        // Stands in for a trackaro-mcp process that has the file open through the restore.
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, me, team) = try filled(database)
        let other = try TrackaroStore.open(at: database.url)
        let agent = try other.agent(named: "Claude Code")
        _ = try store.createIssue(NewIssue(teamId: team.id, title: "Kept"), by: me.id)
        let backup = database.folder.appendingPathComponent("backup.sqlite")
        // A backup that has never heard of this agent.
        let fresh = TemporaryDatabase.sibling(of: database)
        let older = try TrackaroStore.open(at: fresh)
        let olderMe = try older.localUser()
        let olderTeam = try older.createTeam(key: "OLD", name: "Older", by: olderMe.id)
        _ = try older.createIssue(NewIssue(teamId: olderTeam.id, title: "From the backup"), by: olderMe.id)
        try older.backup(to: backup)

        try store.restore(from: backup, safetyCopy: database.folder.appendingPathComponent("safety.sqlite"))

        #expect(try other.issue("OLD-1").title == "From the backup")
        let written = try other.createIssue(NewIssue(teamId: olderTeam.id, title: "Agent keeps working"), by: agent.id)
        #expect(try store.issue(written.id).title == "Agent keeps working")
    }

    @Test func restoredHistoryIsNotReportedAsNew() throws {
        // A column automation runs a shell command on a user's move, so replaying a backup's moves must not fire it.
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, me, team) = try filled(database)
        let staleCursor = try store.feedHead()
        let issue = try store.createIssue(NewIssue(teamId: team.id, title: "Moved in the backup"), by: me.id)
        _ = try store.updateIssue(issue.id, IssuePatch(title: "Moved again"), by: me.id)
        let backup = database.folder.appendingPathComponent("backup.sqlite")
        try store.backup(to: backup)

        try store.restore(from: backup, safetyCopy: database.folder.appendingPathComponent("safety.sqlite"))

        let replayed = try store.feed(after: staleCursor, memberKinds: [.user])
        #expect(replayed.events.isEmpty)
        _ = try store.updateIssue(issue.id, IssuePatch(title: "New after the restore"), by: me.id)
        #expect(try store.feed(after: replayed.cursor, memberKinds: [.user]).events.count == 1)
    }

    @Test func aCursorAheadOfAnOlderBackupStillSeesNewChanges() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, me, team) = try filled(database)
        let issue = try store.createIssue(NewIssue(teamId: team.id, title: "One"), by: me.id)
        let backup = database.folder.appendingPathComponent("backup.sqlite")
        try store.backup(to: backup)
        for number in 0..<5 { _ = try store.updateIssue(issue.id, IssuePatch(title: "Edit \(number)"), by: me.id) }
        let aheadCursor = try store.feedHead()

        try store.restore(from: backup, safetyCopy: database.folder.appendingPathComponent("safety.sqlite"))
        _ = try store.updateIssue(issue.id, IssuePatch(title: "After"), by: me.id)

        #expect(try store.feed(after: aheadCursor, memberKinds: [.user]).events.count == 1)
    }

    @Test func restoringA011BackupUpgradesIt() throws {
        let old = try TemporaryDatabase()
        defer { old.remove() }
        try old.createAsReleased011()
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, _, _) = try filled(database)

        let result = try store.restore(from: old.url, safetyCopy: database.folder.appendingPathComponent("safety.sqlite"))

        #expect(result.issueCount == 1)
        #expect(try store.issue("ENG-1").title == "Written by 0.1.1")
        #expect(try store.artifacts().isEmpty)
    }

    @Test(arguments: ["not a database at all", ""])
    func aBadFileChangesNothing(contents: String) throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, me, team) = try filled(database)
        _ = try store.createIssue(NewIssue(teamId: team.id, title: "Still here"), by: me.id)
        let bad = database.folder.appendingPathComponent("bad.sqlite")
        try Data(contents.utf8).write(to: bad)
        let safety = database.folder.appendingPathComponent("safety.sqlite")

        #expect(throws: TrackaroError.self) { try store.restore(from: bad, safetyCopy: safety) }

        #expect(try store.issue("ENG-1").title == "Still here")
        #expect(!FileManager.default.fileExists(atPath: safety.path))
    }

    @Test func anotherSQLiteFileIsRefused() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, _, _) = try filled(database)
        let other = database.folder.appendingPathComponent("other.sqlite")
        let queue = try DatabaseQueue(path: other.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY)") }
        try queue.close()

        let error = #expect(throws: TrackaroError.self) {
            try store.restore(from: other, safetyCopy: database.folder.appendingPathComponent("safety.sqlite"))
        }
        #expect(error?.description.contains("not a Trackaro backup") == true)
    }

    @Test func aBackupFromANewerVersionIsRefusedWithAnExplanation() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, me, team) = try filled(database)
        _ = try store.createIssue(NewIssue(teamId: team.id, title: "Still here"), by: me.id)
        let newer = database.folder.appendingPathComponent("newer.sqlite")
        try store.backup(to: newer)
        let queue = try DatabaseQueue(path: newer.path)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')") }
        try queue.close()

        let error = #expect(throws: TrackaroError.self) {
            try store.restore(from: newer, safetyCopy: database.folder.appendingPathComponent("safety.sqlite"))
        }

        #expect(error?.description.contains("newer version") == true)
        #expect(try store.issue("ENG-1").title == "Still here")
    }

    @Test func dailyBackupsRunOnceADayAndKeepTheLastSeven() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, _, _) = try filled(database)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(try store.backupIfDue(in: database.backups, now: start) != nil)
        #expect(try store.backupIfDue(in: database.backups, now: start.addingTimeInterval(3600)) == nil)
        for day in 1...9 {
            try store.backupIfDue(in: database.backups, now: start.addingTimeInterval(Double(day) * 86_400))
        }

        let daily = database.backups.entries().filter { $0.kind == .daily }
        #expect(daily.count == 7)
        #expect(daily.first?.createdAt == start.addingTimeInterval(9 * 86_400))
    }

    @Test func manualBackupsAreNeverPruned() throws {
        let database = try TemporaryDatabase()
        defer { database.remove() }
        let (store, _, _) = try filled(database)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for hour in 0..<12 {
            try store.backup(to: database.backups.newURL(.manual, at: start.addingTimeInterval(Double(hour) * 3600)))
        }

        try database.backups.prune(.manual)

        #expect(database.backups.entries().count == 12)
    }
}

private extension TemporaryDatabase {
    /// A database path beside this one that nothing has opened.
    static func sibling(of database: TemporaryDatabase) -> URL {
        database.folder.appendingPathComponent("older/trackaro.sqlite")
    }
}
