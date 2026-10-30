import Foundation

/// The lifecycle timestamps an issue carries, and how a state change rewrites them.
public struct StateTimestamps: Equatable, Sendable {
    public var startedAt: Date?
    public var completedAt: Date?
    public var canceledAt: Date?
    public var stateEnteredAt: Date

    public init(startedAt: Date? = nil, completedAt: Date? = nil, canceledAt: Date? = nil, stateEnteredAt: Date) {
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.canceledAt = canceledAt
        self.stateEnteredAt = stateEnteredAt
    }

    /// Entering a category stamps the matching timestamp and clears the ones it contradicts.
    /// Work that was started keeps its original start time through review and completion.
    public func entering(_ category: StateCategory, at now: Date) -> StateTimestamps {
        var next = self
        next.stateEnteredAt = now
        switch category {
        case .completed:
            next.startedAt = startedAt ?? now
            next.completedAt = now
            next.canceledAt = nil
        case .canceled:
            next.canceledAt = now
            next.completedAt = nil
        case .started, .review:
            next.startedAt = startedAt ?? now
            next.completedAt = nil
            next.canceledAt = nil
        case .triage, .backlog, .unstarted:
            next.startedAt = nil
            next.completedAt = nil
            next.canceledAt = nil
        }
        return next
    }
}

extension Issue {
    var stateTimestamps: StateTimestamps {
        get {
            StateTimestamps(startedAt: startedAt, completedAt: completedAt, canceledAt: canceledAt, stateEnteredAt: stateEnteredAt)
        }
        set {
            startedAt = newValue.startedAt
            completedAt = newValue.completedAt
            canceledAt = newValue.canceledAt
            stateEnteredAt = newValue.stateEnteredAt
        }
    }
}

public enum DefaultWorkflow {
    public struct StateTemplate: Sendable {
        public let name: String
        public let category: StateCategory
        public let color: String
    }

    public static let states: [StateTemplate] = [
        StateTemplate(name: "Triage", category: .triage, color: "#F2994A"),
        StateTemplate(name: "Backlog", category: .backlog, color: "#95A2B3"),
        StateTemplate(name: "Todo", category: .unstarted, color: "#E2E2E2"),
        StateTemplate(name: "In Progress", category: .started, color: "#F2C94C"),
        StateTemplate(name: "In Review", category: .review, color: "#4CB782"),
        StateTemplate(name: "Done", category: .completed, color: "#5E6AD2"),
        StateTemplate(name: "Canceled", category: .canceled, color: "#95A2B3"),
        StateTemplate(name: "Duplicate", category: .canceled, color: "#95A2B3"),
    ]

    /// Where a new issue lands when the caller names no state.
    static let preferredInitialCategories: [StateCategory] = [.backlog, .unstarted, .triage]
}
