import Foundation
import GRDB

extension TrackaroStore {
    /// Changes an issue's state, team or position in one step. This is the only way to change teams.
    ///
    /// Changing teams gives the issue a new identifier from the target team's counter and keeps the old one as an
    /// alias, so `ENG-4` still resolves after it becomes `OPS-1`. Without an explicit state, the issue keeps its
    /// category in the new team. Its cycle and any labels owned by the old team are removed.
    public func moveIssue(_ id: String, _ move: IssueMove, by memberId: String) throws -> IssueChange {
        try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            var issue = try resolveIssue(db, id)
            let originalTeam = issue.teamId
            let originalState = issue.stateId
            var deltas: [FieldDelta] = []

            if let teamId = move.teamId, teamId != issue.teamId {
                deltas += try changeTeam(db, &issue, to: teamId, stateId: move.stateId, at: now)
            } else if let stateId = move.stateId, stateId != issue.stateId {
                let state = try requireState(db, stateId)
                guard state.teamId == issue.teamId else {
                    throw TrackaroError.invalid(field: "state", message: "\(state.name) belongs to another team. Pass the team too.")
                }
                deltas.append(enterState(&issue, state, at: now))
            }

            let columnChanged = issue.teamId != originalTeam || issue.stateId != originalState
            var positionChanged = false
            if let key = try positionKey(db, for: issue, after: move.afterIssue, before: move.beforeIssue, columnChanged: columnChanged),
               key != issue.sortKey {
                issue.sortKey = key
                positionChanged = true
            }

            guard !deltas.isEmpty || positionChanged else { return IssueChange(issue: issue, changed: []) }
            try commit(db, &issue, deltas, by: memberId, at: now)
            return IssueChange(issue: issue, changed: deltas.map(\.field) + (positionChanged ? [.position] : []))
        }
    }

    private func enterState(_ issue: inout Issue, _ state: WorkflowState, at now: Date) -> FieldDelta {
        let delta = FieldDelta(field: .state, from: Self.json(issue.stateId), to: Self.json(state.id))
        issue.stateId = state.id
        issue.stateTimestamps = issue.stateTimestamps.entering(state.category, at: now)
        return delta
    }

    private func changeTeam(_ db: Database, _ issue: inout Issue, to teamId: String, stateId: String?, at now: Date) throws -> [FieldDelta] {
        let target = try activeTeam(db, teamId)
        let currentState = try requireState(db, issue.stateId)
        let targetState: WorkflowState
        if let stateId {
            targetState = try requireState(db, stateId)
            guard targetState.teamId == target.id else {
                throw TrackaroError.invalid(field: "state", message: "\(targetState.name) does not belong to \(target.key).")
            }
        } else {
            let candidates = try orderedStates(db, teamId: target.id)
            targetState = try candidates.first { $0.category == currentState.category } ?? initialState(db, teamId: target.id)
        }

        var deltas: [FieldDelta] = []
        let number = try allocateNumber(db, teamId: target.id, at: now)
        let newIdentifier = "\(target.key)-\(number)"
        try IssueAlias(identifier: issue.identifier, issueId: issue.id).insert(db)
        deltas.append(FieldDelta(field: .team, from: Self.json(issue.identifier), to: Self.json(newIdentifier)))
        issue.teamId = target.id
        issue.number = number
        issue.identifier = newIdentifier

        if let cycleId = issue.cycleId {
            deltas.append(FieldDelta(field: .cycle, from: Self.json(cycleId), to: nil))
            issue.cycleId = nil
        }

        let foreignLabels = try String.fetchAll(db, sql: """
            SELECT issueLabel.labelId FROM issueLabel
            JOIN label ON label.id = issueLabel.labelId
            WHERE issueLabel.issueId = ? AND label.teamId IS NOT NULL AND label.teamId <> ?
            """, arguments: [issue.id, target.id])
        if !foreignLabels.isEmpty {
            let before = try String.fetchAll(db, sql: "SELECT labelId FROM issueLabel WHERE issueId = ?", arguments: [issue.id])
            for labelId in foreignLabels {
                try IssueLabelLink(issueId: issue.id, labelId: labelId).delete(db)
            }
            let after = Set(before).subtracting(foreignLabels)
            deltas.append(FieldDelta(field: .labels, from: Self.json(before.sorted()), to: Self.json(after.sorted())))
        }

        if targetState.id != issue.stateId {
            deltas.append(enterState(&issue, targetState, at: now))
        }
        return deltas
    }

    /// The sort key for the requested position, or nil when the position should not change.
    ///
    /// With one neighbour, the issue goes directly next to it, between it and whatever currently sits on the
    /// other side. With none, an issue that changed column goes to the top and one that did not stays put.
    func positionKey(_ db: Database, for issue: Issue, after: String?, before: String?, columnChanged: Bool) throws -> String? {
        if after == nil, before == nil {
            return columnChanged ? try topSortKey(db, teamId: issue.teamId, stateId: issue.stateId, excluding: issue.id) : nil
        }
        let lower = try after.map { try neighbour(db, $0, of: issue) }
        let upper = try before.map { try neighbour(db, $0, of: issue) }
        var lowerKey = lower?.sortKey
        var upperKey = upper?.sortKey
        if let lowerKey, upper == nil {
            upperKey = try String.fetchOne(db, sql: """
                SELECT MIN(sortKey) FROM issue WHERE teamId = ? AND stateId = ? AND id <> ? AND sortKey > ?
                """, arguments: [issue.teamId, issue.stateId, issue.id, lowerKey])
        }
        if let upperKey, lower == nil {
            lowerKey = try String.fetchOne(db, sql: """
                SELECT MAX(sortKey) FROM issue WHERE teamId = ? AND stateId = ? AND id <> ? AND sortKey < ?
                """, arguments: [issue.teamId, issue.stateId, issue.id, upperKey])
        }
        if let lowerKey, let upperKey, !(lowerKey < upperKey) {
            throw TrackaroError.invalid(field: "position", message: "The issue to place after must sit above the issue to place before.")
        }
        return try sortKey(between: lowerKey, and: upperKey)
    }

    private func neighbour(_ db: Database, _ reference: String, of issue: Issue) throws -> Issue {
        let other = try resolveIssue(db, reference)
        guard other.id != issue.id else {
            throw TrackaroError.invalid(field: "position", message: "An issue cannot be placed next to itself.")
        }
        guard other.teamId == issue.teamId, other.stateId == issue.stateId else {
            throw TrackaroError.invalid(field: "position", message: "\(other.identifier) is in a different column.")
        }
        return other
    }

    func topSortKey(_ db: Database, teamId: String, stateId: String, excluding id: String) throws -> String {
        let first = try String.fetchOne(db, sql: """
            SELECT MIN(sortKey) FROM issue WHERE teamId = ? AND stateId = ? AND id <> ?
            """, arguments: [teamId, stateId, id])
        return try sortKey(between: nil, and: first)
    }

    func sortKey(between lower: String?, and upper: String?) throws -> String {
        do {
            return try FractionalIndex.key(between: lower, and: upper)
        } catch let error as FractionalIndex.InvalidKey {
            throw TrackaroError.invalid(field: "position", message: error.reason)
        }
    }
}
