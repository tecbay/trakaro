import AppKit
import Foundation
import TrackaroCore
import TrackaroKit

/// Writes. Every edit goes through `edit(_:on:patch:)`, which records an undo step covering all the issues it
/// touched, then reloads so the list and inspector show the stored result.
extension AppModel {
    /// Applies a patch built per issue. Returning nil from `patch` skips that issue.
    func edit(_ label: String, on ids: [String], patch: (Issue) throws -> IssuePatch?) {
        guard let store, let user, !ids.isEmpty else { return }
        var edits: [IssueEdit] = []
        do {
            for id in ids {
                let issue = try store.issue(id)
                guard let patch = try patch(issue) else { continue }
                let change = try store.updateIssue(issue.id, patch, by: user.id)
                edits.append(IssueEdit(original: issue, updated: change.issue, changed: change.changed))
            }
        } catch {
            showError(error)
        }
        history.record(EditBatch(label: label, edits: edits))
        reloadAll()
    }

    func setState(_ state: WorkflowState, on ids: [String]) {
        guard let snapshot else { return }
        edit("Change status", on: ids) { issue in
            if state.teamId == issue.teamId { return IssuePatch(stateId: state.id) }
            let teamStates = snapshot.states(ofTeam: issue.teamId)
            let match = teamStates.first { $0.name.caseInsensitiveCompare(state.name) == .orderedSame }
                ?? teamStates.first { $0.category == state.category }
            return match.map { IssuePatch(stateId: $0.id) }
        }
    }

    func setPriority(_ priority: Priority, on ids: [String]) {
        edit("Change priority", on: ids) { _ in IssuePatch(priority: priority) }
    }

    func setAssignee(_ memberId: String?, on ids: [String]) {
        edit(memberId == nil ? "Unassign" : "Assign", on: ids) { _ in IssuePatch(assigneeId: memberId.map(FieldUpdate.set) ?? .clear) }
    }

    func setEstimate(_ points: Int?, on ids: [String]) {
        edit("Set estimate", on: ids) { _ in IssuePatch(estimate: points.map(FieldUpdate.set) ?? .clear) }
    }

    func setProject(_ projectId: String?, on ids: [String]) {
        edit("Set project", on: ids) { _ in IssuePatch(projectId: projectId.map(FieldUpdate.set) ?? .clear) }
    }

    func setMilestone(_ milestoneId: String?, on ids: [String]) {
        edit("Set milestone", on: ids) { _ in IssuePatch(milestoneId: milestoneId.map(FieldUpdate.set) ?? .clear) }
    }

    func setCycle(_ cycleId: String?, on ids: [String]) {
        edit("Set cycle", on: ids) { _ in IssuePatch(cycleId: cycleId.map(FieldUpdate.set) ?? .clear) }
    }

    func setDueDate(_ date: CalendarDate?, on ids: [String]) {
        edit("Set due date", on: ids) { _ in IssuePatch(dueDate: date.map(FieldUpdate.set) ?? .clear) }
    }

    func setTitle(_ title: String, of id: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit("Rename", on: [id]) { issue in issue.title == trimmed ? nil : IssuePatch(title: trimmed) }
    }

    func setDescription(_ text: String, of id: String) {
        edit("Edit description", on: [id]) { issue in issue.description == text ? nil : IssuePatch(description: text) }
    }

    /// Adds the label to every target unless all of them already have it, in which case it is removed from all.
    func toggleLabel(_ labelId: String, on ids: [String]) {
        guard let store, let user, !ids.isEmpty else { return }
        do {
            let current = try Dictionary(uniqueKeysWithValues: ids.map { ($0, try store.labels(forIssue: $0).map(\.id)) })
            let removing = current.values.allSatisfy { $0.contains(labelId) }
            var edits: [IssueEdit] = []
            for id in ids {
                let before = current[id] ?? []
                let change = removing
                    ? try store.removeLabels([labelId], from: id, by: user.id)
                    : try store.addLabels([labelId], to: id, by: user.id)
                guard !change.changed.isEmpty else { continue }
                let after = removing ? before.filter { $0 != labelId } : before + [labelId]
                edits.append(.labels(issueId: id, before: before, after: after))
            }
            history.record(EditBatch(label: removing ? "Remove label" : "Add label", edits: edits))
        } catch {
            showError(error)
        }
        reloadAll()
    }

    func assignToMe() {
        guard let user else { return }
        let ids = targets
        guard let store else { return }
        let allMine = ids.allSatisfy { (try? store.issue($0).assigneeId) == user.id }
        setAssignee(allMine ? nil : user.id, on: ids)
    }

    func archiveTargets() {
        guard let store, let user else { return }
        let ids = targets
        guard !ids.isEmpty else { return }
        do {
            let identifiers = try ids.map { try store.archiveIssue($0, by: user.id).issue.identifier }
            showToast(identifiers.count == 1 ? "Archived \(identifiers[0])" : "Archived \(identifiers.count) issues")
        } catch {
            showError(error)
        }
        selection = []
        reloadAll()
    }

    func copyIdentifiers() {
        guard let store else { return }
        let identifiers = targets.compactMap { try? store.issue($0).identifier }
        guard !identifiers.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(identifiers.joined(separator: " "), forType: .string)
        showToast("Copied \(identifiers.joined(separator: ", "))")
    }

    func addComment(_ body: String, to id: String) {
        guard let store, let user else { return }
        do {
            try store.addComment(to: id, body: body, by: user.id)
        } catch {
            showError(error)
        }
        reloadAll()
    }

    @discardableResult
    func createIssue(_ input: NewIssue) -> Issue? {
        guard let store, let user else { return nil }
        do {
            let issue = try store.createIssue(input, by: user.id)
            reloadAll()
            if rows.contains(where: { $0.issueId == issue.id }) || columns.contains(where: { $0.cards.contains { $0.id == issue.id } }) {
                select([issue.id], cursor: issue.id)
                showToast("Created \(issue.identifier)")
            } else {
                let home = SidebarItem.team(issue.teamId, .all).title(in: snapshot)
                showToast("Created \(issue.identifier) in \(home). It doesn't match this list.")
            }
            return issue
        } catch {
            showError(error)
            return nil
        }
    }

    func undo() {
        guard let store, let user else { return }
        do {
            if let batch = try history.undo(in: store, by: user.id) { showToast("Undid \(batch.label.lowercased())") }
        } catch {
            showError(error)
        }
        reloadAll()
    }

    func redo() {
        guard let store, let user else { return }
        do {
            if let batch = try history.redo(in: store, by: user.id) { showToast("Redid \(batch.label.lowercased())") }
        } catch {
            showError(error)
        }
        reloadAll()
    }

    /// The team new issues go to: the one being viewed, else the first.
    /// Who a new issue is assigned to by default, so it shows up in the list it was created from: you in
    /// My issues, or the one person a filter or view is narrowed to.
    var defaultAssigneeId: String? {
        if currentItem == .myIssues { return user?.id }
        let people = filter.assigneeIds?.filter { $0 != IssueFilter.unset } ?? []
        return people.count == 1 && filter.assigneeIds?.count == 1 ? people.first : nil
    }

    var defaultTeamId: String? {
        boardTeamId ?? snapshot?.teams.first(where: { $0.archivedAt == nil })?.id
    }
}
