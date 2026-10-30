import Foundation

/// The fixed bucket every workflow state maps to. Order is the natural lifecycle order.
public enum StateCategory: String, Codable, CaseIterable, Sendable, Comparable {
    case triage, backlog, unstarted, started, review, completed, canceled

    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public var isOpen: Bool { self != .completed && self != .canceled }

    public static func < (lhs: StateCategory, rhs: StateCategory) -> Bool { lhs.rank < rhs.rank }
}

/// Stored as 0 to 4. `none` is 0 in storage but sorts last; use `sortRank` for ordering.
public enum Priority: Int, Codable, CaseIterable, Sendable {
    case none = 0, urgent = 1, high = 2, medium = 3, low = 4

    public var name: String {
        switch self {
        case .none: "none"
        case .urgent: "urgent"
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        }
    }

    public init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = match
    }

    public var sortRank: Int { self == .none ? 5 : rawValue }
}

public enum RelationType: String, Codable, CaseIterable, Sendable {
    case blocks
    case blockedBy = "blocked_by"
    case related
    case duplicateOf = "duplicate_of"
    case duplicatedBy = "duplicated_by"

    public var inverse: RelationType {
        switch self {
        case .blocks: .blockedBy
        case .blockedBy: .blocks
        case .related: .related
        case .duplicateOf: .duplicatedBy
        case .duplicatedBy: .duplicateOf
        }
    }
}

public enum MemberKind: String, Codable, CaseIterable, Sendable {
    case user, agent, system
}

public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case backlog, planned
    case inProgress = "in_progress"
    case completed, canceled
}

public enum ProjectHealth: String, Codable, CaseIterable, Sendable {
    case onTrack = "on_track"
    case atRisk = "at_risk"
    case offTrack = "off_track"
    case noUpdate = "no_update"
}

public enum ViewLayout: String, Codable, CaseIterable, Sendable {
    case list, board
}

public enum ChangeAction: String, Codable, CaseIterable, Sendable {
    case insert, update, delete, archive, unarchive
}

/// Issue fields as they appear in activity history and in `IssueChange.changed`.
public enum IssueField: String, Codable, CaseIterable, Sendable {
    case created, title, description, state, priority, estimate, dueDate, assignee
    case parent, project, milestone, cycle, labels, team, position, archived, relation
}
