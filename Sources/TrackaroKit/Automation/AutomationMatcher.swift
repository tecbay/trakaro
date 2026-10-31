import Foundation
import TrackaroCore

/// An automation to start for one issue.
public struct PlannedRun: Equatable, Sendable {
    public let automation: Automation
    public let issue: Issue

    public init(automation: Automation, issue: Issue) {
        self.automation = automation
        self.issue = issue
    }
}

/// Decides which automations a batch of feed events starts.
///
/// A rule fires when the person using the app moves an issue into its column, or creates one there. Agents never
/// trigger rules: an agent moving its own issue into "Ready for agent" must not start another agent, or two rules
/// could feed each other forever. The issue must still be in the column when the event is read, so dragging a card
/// through a column on the way somewhere else starts nothing, and one issue gets at most one run per rule at a time.
public enum AutomationMatcher {
    public static func runs(for events: [FeedEvent], automations: [Automation], running: [AutomationRun]) -> [PlannedRun] {
        let rules = Dictionary(grouping: automations.filter(\.enabled), by: \.stateId)
        guard !rules.isEmpty else { return [] }
        var busy = Set(running.filter { $0.status == .running }.map { "\($0.automationId)/\($0.issueId)" })
        var planned: [PlannedRun] = []
        for event in events where event.member.kind == .user {
            guard case let .activity(activity) = event.kind, let entered = enteredState(activity, issue: event.issue) else { continue }
            let issue = event.issue
            guard issue.stateId == entered, issue.archivedAt == nil else { continue }
            for automation in rules[entered] ?? [] {
                let key = "\(automation.id)/\(issue.id)"
                guard !busy.contains(key) else { continue }
                busy.insert(key)
                planned.append(PlannedRun(automation: automation, issue: issue))
            }
        }
        return planned
    }

    private static func enteredState(_ activity: IssueActivity, issue: Issue) -> String? {
        switch activity.field {
        case .state: decodedString(activity.toValue)
        case .created: issue.stateId
        default: nil
        }
    }

    private static func decodedString(_ json: String?) -> String? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }
}

/// Fills an automation's prompt template from the issue.
public enum AutomationPrompt {
    public static let placeholders = ["identifier", "title", "state", "team", "url", "description"]

    public static func render(_ template: String, issue: Issue, snapshot: WorkspaceSnapshot) -> String {
        let values: [String: String] = [
            "identifier": issue.identifier,
            "title": issue.title,
            "state": snapshot.statesById[issue.stateId]?.name ?? "",
            "team": snapshot.teamsById[issue.teamId]?.name ?? "",
            "url": AppLink.issueURL(issue.identifier)?.absoluteString ?? "",
            "description": issue.description,
        ]
        var result = template
        for (name, value) in values { result = result.replacingOccurrences(of: "{\(name)}", with: value) }
        return result
    }
}
