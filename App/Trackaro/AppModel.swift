import Foundation
import Observation
import os
import TrackaroCore

/// Holds the open store and the slice of data the window shows.
///
/// Agents write through `trackaro-mcp`, a separate process on the same database. The model notices their writes
/// by polling the change log's high-water mark, which is one indexed lookup, and reloads only when it moved.
@MainActor
@Observable
final class AppModel {
    private(set) var team: Team?
    private(set) var states: [WorkflowState] = []
    private(set) var issues: [Issue] = []
    private(set) var errorMessage: String?
    private var memberNames: [String: String] = [:]

    private var store: TrackaroStore?
    private var me: Member?
    private var seenChangeSeq: Int64 = 0
    private var watcher: Task<Void, Never>?

    private static let log = Logger(subsystem: "app.trackaro.Trackaro", category: "sync")
    static let pollInterval: Duration = .milliseconds(300)

    /// The database file: `TRACKARO_DATABASE` when set, which keeps development runs off real data.
    static func databaseURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["TRACKARO_DATABASE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return try TrackaroStore.defaultURL()
    }

    func start() {
        guard store == nil else { return }
        do {
            let store = try TrackaroStore.open(at: Self.databaseURL())
            let me = try store.localUser()
            let team = try store.teams().first ?? store.createTeam(key: "TASK", name: "Tasks", by: me.id)
            self.store = store
            self.me = me
            self.team = team
            try reload()
            watchForExternalChanges()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func createIssue(title: String) {
        guard let store, let me, let team else { return }
        perform {
            _ = try store.createIssue(NewIssue(teamId: team.id, title: title), by: me.id)
        }
    }

    func move(_ issue: Issue, to state: WorkflowState) {
        guard let store, let me else { return }
        perform {
            _ = try store.moveIssue(issue.id, IssueMove(stateId: state.id), by: me.id)
        }
    }

    func issues(in state: WorkflowState) -> [Issue] {
        issues.filter { $0.stateId == state.id }
    }

    func memberName(_ id: String?) -> String? {
        id.flatMap { memberNames[$0] }
    }

    private func perform(_ write: () throws -> Void) {
        do {
            try write()
            try reload()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func reload() throws {
        guard let store else { return }
        seenChangeSeq = try store.latestChangeSeq()
        if let current = team, let refreshed = try store.teams().first(where: { $0.id == current.id }) {
            team = refreshed
        }
        guard let team else { return }
        memberNames = Dictionary(uniqueKeysWithValues: try store.members().map { ($0.id, $0.name) })
        states = try store.states(teamId: team.id)
        issues = try store.issues(teamId: team.id)
    }

    private func watchForExternalChanges() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.reloadIfChangedElsewhere()
            }
        }
    }

    private func reloadIfChangedElsewhere() {
        guard let store, let latest = try? store.latestChangeSeq(), latest != seenChangeSeq else { return }
        do {
            try reload()
            Self.log.info("Reloaded after external change, cursor \(latest), \(self.issues.count) issues")
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
