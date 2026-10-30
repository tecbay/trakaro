import Foundation
import Observation
import TrackaroCore

/// Holds the open store and the slice of data the window shows. Phase 1 keeps this deliberately small:
/// it proves the app can open the real database, read and write through `TrackaroStore`.
@MainActor
@Observable
final class AppModel {
    private(set) var team: Team?
    private(set) var states: [WorkflowState] = []
    private(set) var issues: [Issue] = []
    private(set) var errorMessage: String?

    private var store: TrackaroStore?
    private var me: Member?

    func start() {
        guard store == nil else { return }
        do {
            let store = try TrackaroStore.open(at: TrackaroStore.defaultURL())
            let me = try store.localUser()
            let team = try store.teams().first ?? store.createTeam(key: "TASK", name: "Tasks", by: me.id)
            self.store = store
            self.me = me
            self.team = team
            try reload()
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
        guard let store, let team else { return }
        states = try store.states(teamId: team.id)
        issues = try store.issues(teamId: team.id)
    }
}
