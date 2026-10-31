import Foundation
import Testing
@testable import TrackaroCore
@testable import TrackaroKit

@Suite("Cycles and projects presentation")
struct PlanningTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 3, day: day, hour: hour)) ?? Date()
    }

    private func cycle(start: Int, end: Int, completed: Date? = nil) -> Cycle {
        Cycle(id: "c", teamId: "t", number: 3, name: nil, startsAt: date(start, hour: 0), endsAt: date(end, hour: 0),
              completedAt: completed, createdAt: date(1), updatedAt: date(1))
    }

    @Test func timingDescribesEachPhase() {
        let week = cycle(start: 3, end: 10)
        #expect(CycleTiming.phase(week, now: date(1)) == .upcoming)
        #expect(CycleTiming.status(week, now: date(1), calendar: calendar) == "Starts in 2 days")
        #expect(CycleTiming.status(week, now: date(2), calendar: calendar) == "Starts tomorrow")
        #expect(CycleTiming.phase(week, now: date(5)) == .current)
        #expect(CycleTiming.status(week, now: date(5), calendar: calendar) == "5 days left")
        #expect(CycleTiming.status(week, now: date(9), calendar: calendar) == "1 day left")
        #expect(CycleTiming.phase(week, now: date(12)) == .overdue)
        #expect(CycleTiming.status(week, now: date(12), calendar: calendar) == "Ended 2 days ago")
        #expect(CycleTiming.status(cycle(start: 3, end: 10, completed: date(10)), now: date(12), calendar: calendar) == "Completed")
        #expect(CycleTiming.title(week) == "Cycle 3")
    }

    @Test func burnUpCountsCompletionsPerDayUpToToday() {
        let completions = [date(2), date(3, hour: 9), date(3, hour: 23), date(5), date(20)]
        let points = BurnUp.points(start: date(3, hour: 0), end: date(10, hour: 0), now: date(5, hour: 18),
                                   completions: completions, calendar: calendar)
        #expect(points.map(\.completed) == [3, 3, 4])
        #expect(points.first?.day == date(3, hour: 0))

        let finished = BurnUp.points(start: date(3, hour: 0), end: date(10, hour: 0), now: date(30), completions: completions, calendar: calendar)
        #expect(finished.count == 7)
        #expect(finished.last?.completed == 4)
        #expect(BurnUp.points(start: date(3), end: date(10), now: date(1), completions: [], calendar: calendar).isEmpty)
    }
}
