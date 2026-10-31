import Foundation
import TrackaroCore

/// Where a cycle is in time, and how to say it.
public enum CycleTiming {
    public enum Phase: Equatable, Sendable {
        case upcoming, current, completed
        /// Past its end date but nobody completed it yet.
        case overdue
    }

    public static func phase(_ cycle: Cycle, now: Date) -> Phase {
        if cycle.completedAt != nil { return .completed }
        if now < cycle.startsAt { return .upcoming }
        return now < cycle.endsAt ? .current : .overdue
    }

    public static func title(_ cycle: Cycle) -> String {
        cycle.name.map { "Cycle \(cycle.number) · \($0)" } ?? "Cycle \(cycle.number)"
    }

    /// "Mar 3 – Mar 10"
    public static func range(_ cycle: Cycle, calendar: Calendar = .current) -> String {
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted).month(.abbreviated).day()
        let lastDay = calendar.date(byAdding: .second, value: -1, to: cycle.endsAt) ?? cycle.endsAt
        return "\(cycle.startsAt.formatted(format)) – \(lastDay.formatted(format))"
    }

    /// "3 days left", "Starts tomorrow", "Ended 2 days ago", "Completed"
    public static func status(_ cycle: Cycle, now: Date, calendar: Calendar = .current) -> String {
        switch phase(cycle, now: now) {
        case .completed:
            return "Completed"
        case .upcoming:
            let days = wholeDays(from: now, to: cycle.startsAt, calendar: calendar)
            return days <= 0 ? "Starts today" : days == 1 ? "Starts tomorrow" : "Starts in \(days) days"
        case .current:
            let days = wholeDays(from: now, to: cycle.endsAt, calendar: calendar)
            return days <= 0 ? "Ends today" : days == 1 ? "1 day left" : "\(days) days left"
        case .overdue:
            let days = wholeDays(from: cycle.endsAt, to: now, calendar: calendar)
            return days <= 0 ? "Ended today" : days == 1 ? "Ended yesterday" : "Ended \(days) days ago"
        }
    }

    private static func wholeDays(from start: Date, to end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }
}

/// One day of a cycle's burn-up: how many issues were completed by the end of that day.
public struct BurnUpPoint: Equatable, Sendable, Identifiable {
    public let day: Date
    public let completed: Int

    public var id: Date { day }
}

public enum BurnUp {
    /// Cumulative completions per day, from the cycle's first day to its last day or today, whichever is earlier.
    /// Work finished before the cycle started counts on the first day.
    public static func points(start: Date, end: Date, now: Date, completions: [Date], calendar: Calendar = .current) -> [BurnUpPoint] {
        let first = calendar.startOfDay(for: start)
        let lastMoment = min(end.addingTimeInterval(-1), now)
        let last = calendar.startOfDay(for: lastMoment)
        guard first <= last else { return [] }
        let sorted = completions.sorted()
        var points: [BurnUpPoint] = []
        var day = first
        var index = 0
        while day <= last {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            while index < sorted.count, sorted[index] < next { index += 1 }
            points.append(BurnUpPoint(day: day, completed: index))
            day = next
        }
        return points
    }
}

extension ProjectStatus {
    public var displayName: String {
        switch self {
        case .backlog: "Backlog"
        case .planned: "Planned"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .canceled: "Canceled"
        }
    }

    public var isActive: Bool { self != .completed && self != .canceled }
}

extension ProjectHealth {
    public var displayName: String {
        switch self {
        case .onTrack: "On track"
        case .atRisk: "At risk"
        case .offTrack: "Off track"
        case .noUpdate: "No update"
        }
    }
}
