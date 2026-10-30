import Foundation
import Testing
@testable import TrackaroCore

@Suite("Value types")
struct ValueTypeTests {
    @Test func issueKeyParsesCaseInsensitively() {
        #expect(IssueKey("eng-42") == IssueKey(teamKey: "ENG", number: 42))
        #expect(IssueKey(" OPS2-7 ")?.description == "OPS2-7")
    }

    @Test("Rejects non-identifiers", arguments: ["ENG", "ENG-", "ENG-0", "1NG-4", "E-4", "ENGINEER-4", "ENG-4a", "ENG--4", ""])
    func issueKeyRejects(text: String) {
        #expect(IssueKey(text) == nil)
    }

    @Test func teamKeyRules() {
        #expect(TeamKey.isValid("EN"))
        #expect(TeamKey.isValid("ENG123"))
        #expect(!TeamKey.isValid("E"))
        #expect(!TeamKey.isValid("ENG1234"))
        #expect(!TeamKey.isValid("9ENG"))
        #expect(!TeamKey.isValid("EN-G"))
        #expect(!TeamKey.isValid("ÉNG"))
    }

    @Test func calendarDateRoundTripsAndValidates() {
        #expect(CalendarDate("2026-02-28")?.description == "2026-02-28")
        #expect(CalendarDate("2028-02-29") != nil)
        #expect(CalendarDate("2026-02-29") == nil)
        #expect(CalendarDate("2026-13-01") == nil)
        #expect(CalendarDate("26-01-01") == nil)
        #expect(CalendarDate("2026-1-01") == nil)
        let earlier = CalendarDate("2026-01-31")
        let later = CalendarDate("2026-02-01")
        #expect(earlier != nil && later != nil)
        if let earlier, let later { #expect(earlier < later) }
    }

    @Test func priorityNoneSortsLast() {
        let sorted = Priority.allCases.sorted { $0.sortRank < $1.sortRank }
        #expect(sorted == [.urgent, .high, .medium, .low, .none])
        #expect(Priority(name: "HIGH") == .high)
        #expect(Priority(name: "critical") == nil)
    }

    @Test func relationInversesAreSymmetric() {
        for type in RelationType.allCases {
            #expect(type.inverse.inverse == type)
        }
        #expect(RelationType.blocks.inverse == .blockedBy)
        #expect(RelationType.related.inverse == .related)
    }

    @Test func uuidV7IsVersionSevenAndTimeOrdered() {
        let early = Identifiers.uuidV7(at: Date(timeIntervalSince1970: 1_700_000_000))
        let late = Identifiers.uuidV7(at: Date(timeIntervalSince1970: 1_700_000_001))
        #expect(early < late)
        let characters = Array(early)
        #expect(characters[14] == "7")
        #expect("89ab".contains(characters[19]))
        #expect(early == early.lowercased())
    }

    @Test func slugify() {
        #expect(TrackaroStore.slugify("Mobile App: Launch!") == "mobile-app-launch")
        #expect(TrackaroStore.slugify("Café Déjà vu") == "cafe-deja-vu")
        #expect(TrackaroStore.slugify("!!!") == "project")
    }
}

@Suite("State timestamps")
struct StateTransitionTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)

    @Test func startingStampsStartedAt() {
        let next = StateTimestamps(stateEnteredAt: t0).entering(.started, at: t1)
        #expect(next.startedAt == t1)
        #expect(next.completedAt == nil)
        #expect(next.canceledAt == nil)
        #expect(next.stateEnteredAt == t1)
    }

    @Test func reviewKeepsOriginalStart() {
        let started = StateTimestamps(startedAt: t0, stateEnteredAt: t0)
        #expect(started.entering(.review, at: t1).startedAt == t0)
    }

    @Test func completingKeepsStartAndClearsCancel() {
        let next = StateTimestamps(startedAt: t0, canceledAt: t0, stateEnteredAt: t0).entering(.completed, at: t1)
        #expect(next.startedAt == t0)
        #expect(next.completedAt == t1)
        #expect(next.canceledAt == nil)
    }

    @Test func completingUnstartedWorkBackfillsStart() {
        let next = StateTimestamps(stateEnteredAt: t0).entering(.completed, at: t1)
        #expect(next.startedAt == t1)
    }

    @Test func cancelingKeepsStartAndClearsCompletion() {
        let next = StateTimestamps(startedAt: t0, completedAt: t0, stateEnteredAt: t0).entering(.canceled, at: t1)
        #expect(next.startedAt == t0)
        #expect(next.canceledAt == t1)
        #expect(next.completedAt == nil)
    }

    @Test("Returning to an unstarted category clears everything", arguments: [StateCategory.triage, .backlog, .unstarted])
    func reopeningClearsAll(category: StateCategory) {
        let next = StateTimestamps(startedAt: t0, completedAt: t0, canceledAt: t0, stateEnteredAt: t0).entering(category, at: t1)
        #expect(next.startedAt == nil)
        #expect(next.completedAt == nil)
        #expect(next.canceledAt == nil)
        #expect(next.stateEnteredAt == t1)
    }
}
