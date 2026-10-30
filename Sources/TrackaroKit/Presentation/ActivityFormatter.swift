import Foundation
import TrackaroCore

/// Turns stored activity into a sentence fragment that follows the actor's name: "moved from Todo to In Progress".
public struct ActivityFormatter: Sendable {
    public let snapshot: WorkspaceSnapshot
    /// Issue id to identifier, for parent changes.
    public let identifiers: [String: String]

    public init(snapshot: WorkspaceSnapshot, identifiers: [String: String] = [:]) {
        self.snapshot = snapshot
        self.identifiers = identifiers
    }

    public func describe(_ entry: IssueActivity) -> String {
        let from = Self.decode(entry.fromValue)
        let to = Self.decode(entry.toValue)
        switch entry.field {
        case .created:
            return "created the issue"
        case .title:
            return "renamed it to “\(string(to) ?? "")”"
        case .description:
            return "updated the description"
        case .state:
            return "moved it from \(name(state: from)) to \(name(state: to))"
        case .priority:
            guard let priority = string(to), priority != Priority.none.name else { return "removed the priority" }
            return "set priority to \(priority.capitalized)"
        case .estimate:
            guard let points = to as? Int else { return "cleared the estimate" }
            return "set the estimate to \(points)"
        case .dueDate:
            guard let date = string(to) else { return "cleared the due date" }
            return "set the due date to \(date)"
        case .assignee:
            if let id = string(to) { return "assigned \(snapshot.membersById[id]?.name ?? "someone")" }
            return "unassigned \(string(from).flatMap { snapshot.membersById[$0]?.name } ?? "it")"
        case .parent:
            if let id = string(to) { return "made it a sub-issue of \(identifiers[id] ?? "another issue")" }
            return "removed the parent"
        case .project:
            if let id = string(to) { return "moved it to project \(snapshot.projectsById[id]?.name ?? "unknown")" }
            return "removed it from \(string(from).flatMap { snapshot.projectsById[$0]?.name } ?? "its project")"
        case .milestone:
            if let id = string(to) { return "set milestone \(snapshot.milestonesById[id]?.name ?? "unknown")" }
            return "removed the milestone"
        case .cycle:
            if let id = string(to) { return "added it to cycle \(snapshot.cyclesById[id].map { String($0.number) } ?? "unknown")" }
            return "removed it from its cycle"
        case .labels:
            return describeLabels(from: strings(from), to: strings(to))
        case .team:
            return "moved it from \(string(from) ?? "?") to \(string(to) ?? "?")"
        case .position:
            return "reordered it"
        case .archived:
            return (to as? Bool) == true ? "archived it" : "restored it"
        case .relation:
            if let added = string(to) { return "linked: \(added.replacingOccurrences(of: "_", with: " "))" }
            return "unlinked: \((string(from) ?? "").replacingOccurrences(of: "_", with: " "))"
        }
    }

    private func describeLabels(from: [String], to: [String]) -> String {
        let added = to.filter { !from.contains($0) }.map(labelName)
        let removed = from.filter { !to.contains($0) }.map(labelName)
        var parts: [String] = []
        if !added.isEmpty { parts.append("added \(added.count == 1 ? "label" : "labels") \(added.joined(separator: ", "))") }
        if !removed.isEmpty { parts.append("removed \(removed.count == 1 ? "label" : "labels") \(removed.joined(separator: ", "))") }
        return parts.isEmpty ? "changed labels" : parts.joined(separator: " and ")
    }

    private func labelName(_ id: String) -> String { snapshot.labelsById[id]?.name ?? "deleted label" }

    private func name(state value: Any?) -> String {
        string(value).flatMap { snapshot.statesById[$0]?.name } ?? "unknown"
    }

    private func string(_ value: Any?) -> String? { value as? String }

    private func strings(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }

    static func decode(_ json: String?) -> Any? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
