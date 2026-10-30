import Foundation
@testable import TrackaroCore

/// A clock that advances one second per reading, so every write in a test has a distinct, predictable time.
final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(1)
        return current
    }
}

struct Fixture {
    let store: TrackaroStore
    let me: Member
    let team: Team

    init(teamKey: String = "ENG") throws {
        let clock = SteppingClock()
        store = try TrackaroStore.inMemory(clock: { clock.now() })
        me = try store.localUser()
        team = try store.createTeam(key: teamKey, name: "Engineering", by: me.id)
    }

    func state(_ name: String, in teamId: String? = nil) throws -> WorkflowState {
        let states = try store.states(teamId: teamId ?? team.id)
        guard let state = states.first(where: { $0.name == name }) else {
            throw TrackaroError.notFound(entity: "state", reference: name)
        }
        return state
    }

    @discardableResult
    func issue(_ title: String, state: String? = nil, teamId: String? = nil) throws -> Issue {
        let teamId = teamId ?? team.id
        let stateId = try state.map { try self.state($0, in: teamId).id }
        return try store.createIssue(NewIssue(teamId: teamId, title: title, stateId: stateId), by: me.id)
    }

    /// Identifiers of a column's issues, top to bottom.
    func column(_ stateName: String, teamId: String? = nil) throws -> [String] {
        let teamId = teamId ?? team.id
        let stateId = try state(stateName, in: teamId).id
        return try store.issues(teamId: teamId).filter { $0.stateId == stateId }.map(\.identifier)
    }
}
