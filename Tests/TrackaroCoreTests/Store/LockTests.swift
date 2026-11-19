import Foundation
import Testing
@testable import TrackaroCore

/// A clock that only moves when told, for expiry.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

@Suite("Locks")
struct LockTests {
    private struct Setup {
        let store: TrackaroStore
        let clock: ManualClock
        let me: Member
        let issues: [TrackaroCore.Issue]

        func request(_ resource: String, _ session: String, issue: Int = 0, ttl: Int = TrackaroStore.defaultLockTTL, processId: Int? = nil) -> LockRequest {
            LockRequest(resource: resource, issue: issues[issue].identifier, sessionId: session, sessionTitle: session, processId: processId, ttlSeconds: ttl)
        }

        func holder(_ resource: String) throws -> LockHolder? {
            try store.lockStates(resource: resource).first?.holder
        }

        func queue(_ resource: String) throws -> [String] {
            try store.lockStates(resource: resource).first?.queue.map(\.sessionId) ?? []
        }
    }

    private func setup() throws -> Setup {
        let clock = ManualClock()
        let store = try TrackaroStore.inMemory(clock: { clock.now() })
        let me = try store.localUser()
        let team = try store.createTeam(key: "ENG", name: "Engineering", by: me.id)
        let issues = try (1...4).map { try store.createIssue(NewIssue(teamId: team.id, title: "Task \($0)"), by: me.id) }
        return Setup(store: store, clock: clock, me: me, issues: issues)
    }

    private func isGranted(_ result: LockAcquisition) -> Bool {
        if case .granted = result { true } else { false }
    }

    private func position(_ result: LockAcquisition) -> Int? {
        if case let .queued(_, position, _) = result { position } else { nil }
    }

    @Test func theMigrationSeedsTheResourcesAndTheQARule() throws {
        let setup = try setup()
        #expect(Set(try setup.store.lockResources().map(\.name)) == [
            "qa-web", "qa-ios", "qa-android", "merge mobicart-be", "merge mobicart-supernative", "merge mobicart-shopify", "merge wordpress-elementor",
        ])
        let states = Dictionary(uniqueKeysWithValues: try setup.store.lockStates().map { ($0.resource, $0.conflictsWith) })
        #expect(states["qa-web"] == ["qa-android", "qa-ios"])
        #expect(states["qa-ios"] == ["qa-web"])
        #expect(states["merge mobicart-be"] == [])
    }

    @Test func concurrentAcquiresFromSeparateConnectionsGrantExactlyOne() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trackaro-locks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("trackaro.sqlite")
        let first = try TrackaroStore.open(at: url)
        let me = try first.localUser()
        let team = try first.createTeam(key: "ENG", name: "Engineering", by: me.id)
        let issue = try first.createIssue(NewIssue(teamId: team.id, title: "Race"), by: me.id)
        // Separate pools on one file stand in for separate trackaro-mcp processes.
        let stores = try [first] + (1..<6).map { _ in try TrackaroStore.open(at: url) }

        for round in 0..<5 {
            let resource = round.isMultiple(of: 2) ? "merge mobicart-be" : "qa-web"
            let results = try await withThrowingTaskGroup(of: LockAcquisition.self) { group in
                for (index, store) in stores.enumerated() {
                    group.addTask {
                        try store.acquireLock(LockRequest(resource: resource, issue: issue.identifier, sessionId: "chat-\(round)-\(index)"))
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(results.filter(isGranted).count == 1)
            #expect(results.compactMap(position).sorted() == Array(1..<stores.count))
            _ = try first.releaseLocks(forSession: "x")
            for index in stores.indices { _ = try first.releaseLocks(forSession: "chat-\(round)-\(index)") }
        }
    }

    @Test func waitersAreServedInOrder() throws {
        let setup = try setup()
        #expect(isGranted(try setup.store.acquireLock(setup.request("qa-ios", "a"))))
        #expect(position(try setup.store.acquireLock(setup.request("qa-ios", "b", issue: 1))) == 1)
        #expect(position(try setup.store.acquireLock(setup.request("qa-ios", "c", issue: 2))) == 2)

        let firstHandOver = try setup.store.releaseLock("qa-ios", sessionId: "a", resultNote: "Passed")
        #expect(firstHandOver.map(\.sessionId) == ["b"])
        #expect(try setup.queue("qa-ios") == ["c"])
        let secondHandOver = try setup.store.releaseLock("qa-ios", sessionId: "b")
        #expect(secondHandOver.map(\.sessionId) == ["c"])
        #expect(try setup.holder("qa-ios")?.sessionId == "c")
        #expect(try setup.queue("qa-ios").isEmpty)
    }

    @Test func qaWebAndTheDeviceLanesExcludeEachOther() throws {
        let setup = try setup()
        #expect(isGranted(try setup.store.acquireLock(setup.request("qa-web", "web"))))
        #expect(position(try setup.store.acquireLock(setup.request("qa-ios", "ios", issue: 1))) == 1)
        #expect(position(try setup.store.acquireLock(setup.request("qa-android", "android", issue: 2))) == 1)

        // Releasing the web lane lets both device lanes go at once: they do not conflict with each other.
        let granted = try setup.store.releaseLock("qa-web", sessionId: "web")
        #expect(Set(granted.map(\.resource)) == ["qa-ios", "qa-android"])

        // And a device lane blocks the web lane in turn.
        if case let .queued(_, position, blockedBy) = try setup.store.acquireLock(setup.request("qa-web", "web-again", issue: 3)) {
            #expect(position == 1)
            #expect(Set(blockedBy.map(\.resource)) == ["qa-ios", "qa-android"])
        } else {
            Issue.record("qa-web should wait while a device lane is held")
        }
    }

    @Test func aWaitingWebRunKeepsItsPlaceAheadOfLaterDeviceRuns() throws {
        let setup = try setup()
        _ = try setup.store.acquireLock(setup.request("qa-ios", "ios"))
        _ = try setup.store.acquireLock(setup.request("qa-web", "web", issue: 1))
        // qa-android is free, but the web run asked first and would be starved if device runs kept slipping past it.
        #expect(position(try setup.store.acquireLock(setup.request("qa-android", "android", issue: 2))) == 1)

        let granted = try setup.store.releaseLock("qa-ios", sessionId: "ios")
        #expect(granted.map(\.sessionId) == ["web"])
        #expect(try setup.queue("qa-android") == ["android"])
    }

    @Test func onlyTheHolderCanReleaseOrHeartbeat() throws {
        let setup = try setup()
        _ = try setup.store.acquireLock(setup.request("qa-web", "a"))
        _ = try setup.store.acquireLock(setup.request("qa-web", "b", issue: 1))

        #expect(throws: TrackaroError.self) { try setup.store.releaseLock("qa-web", sessionId: "b") }
        #expect(throws: TrackaroError.self) { try setup.store.heartbeatLock("qa-web", sessionId: "b") }
        do {
            try setup.store.releaseLock("qa-web", sessionId: "b")
        } catch {
            #expect(String(describing: error).contains("position 1"))
        }
        #expect(try setup.holder("qa-web")?.sessionId == "a")
    }

    @Test func askingAgainFromTheSameChatChangesNothing() throws {
        let setup = try setup()
        #expect(isGranted(try setup.store.acquireLock(setup.request("qa-web", "a"))))
        #expect(isGranted(try setup.store.acquireLock(setup.request("qa-web", "a"))))
        #expect(position(try setup.store.acquireLock(setup.request("qa-web", "b", issue: 1))) == 1)
        #expect(position(try setup.store.acquireLock(setup.request("qa-web", "b", issue: 1))) == 1)
        #expect(try setup.queue("qa-web") == ["b"])
        let kinds = try setup.store.lockHistory(resource: "qa-web").map(\.kind)
        #expect(kinds.filter { $0 == .acquired }.count == 1)
        #expect(kinds.filter { $0 == .queued }.count == 1)
    }

    @Test func expiryHandsTheLockOnAndTellsBothChats() throws {
        let setup = try setup()
        _ = try setup.store.acquireLock(setup.request("qa-web", "a", ttl: 120))
        _ = try setup.store.acquireLock(setup.request("qa-web", "b", issue: 1))
        _ = try setup.store.acquireLock(setup.request("merge mobicart-be", "c", issue: 2))
        let start = try setup.store.lockEventHead()

        setup.clock.advance(by: 60)
        try setup.store.heartbeatLock("qa-web", sessionId: "a")
        setup.clock.advance(by: 100)
        #expect(try setup.store.expireLocks(isProcessAlive: { _ in true }).isEmpty, "a heartbeat pushes expiry back")

        setup.clock.advance(by: 30)
        let expired = try setup.store.expireLocks(isProcessAlive: { _ in true })
        #expect(expired.map(\.targetSessionId) == ["a"])
        #expect(try setup.holder("qa-web")?.sessionId == "b")

        let toA = try setup.store.lockEvents(after: start, for: "a")
        let toB = try setup.store.lockEvents(after: start, for: "b")
        #expect(toA.map(\.kind) == [.expired])
        #expect(toB.map(\.kind) == [.granted])
        #expect(try setup.store.lockEvents(after: start, for: "c").isEmpty, "a chat that is not involved hears nothing")
        // The merge lock's holder never sent a heartbeat either, but its time to live has not run out.
        #expect(try setup.holder("merge mobicart-be")?.sessionId == "c")
    }

    @Test func aChatWhoseProcessEndedLosesItsLockAndItsPlace() throws {
        let setup = try setup()
        _ = try setup.store.acquireLock(setup.request("qa-ios", "a", processId: 111))
        _ = try setup.store.acquireLock(setup.request("qa-ios", "b", issue: 1, processId: 222))
        _ = try setup.store.acquireLock(setup.request("qa-ios", "c", issue: 2, processId: 333))

        try setup.store.expireLocks(isProcessAlive: { $0 != 111 && $0 != 222 })
        #expect(try setup.holder("qa-ios")?.sessionId == "c")

        // A reconnected chat records its new process, so it does not look dead.
        try setup.store.adoptLocks(sessionId: "c", processId: 444)
        try setup.store.expireLocks(isProcessAlive: { $0 == 444 })
        #expect(try setup.holder("qa-ios")?.sessionId == "c")
    }

    @Test func grantedEventsCarryThePreviousHoldersNote() throws {
        let setup = try setup()
        _ = try setup.store.acquireLock(setup.request("merge mobicart-be", "a"))
        _ = try setup.store.acquireLock(setup.request("merge mobicart-be", "b", issue: 1))
        try setup.store.releaseLock("merge mobicart-be", sessionId: "a", resultNote: "Merged #412, main is green")
        let event = try #require(try setup.store.lockEvents(after: 0, for: "b").first)
        #expect(event.kind == .granted)
        #expect(event.detail == "Merged #412, main is green")
        #expect(try setup.store.lockEvents(after: 0, for: "a").isEmpty, "releasing is not news to the releaser")

        // A device lane freed by the web run's release hears that run's note, named.
        _ = try setup.store.acquireLock(setup.request("qa-web", "web", issue: 2))
        _ = try setup.store.acquireLock(setup.request("qa-ios", "ios", issue: 3))
        try setup.store.releaseLock("qa-web", sessionId: "web", resultNote: "Web passed")
        #expect(try setup.store.lockEvents(after: 0, for: "ios").first?.detail == "qa-web: Web passed")
    }

    @Test func forceReleaseTellsTheHolderAndServesTheQueue() throws {
        let setup = try setup()
        _ = try setup.store.acquireLock(setup.request("qa-android", "a"))
        _ = try setup.store.acquireLock(setup.request("qa-android", "b", issue: 1))
        let granted = try setup.store.forceReleaseLock("qa-android", by: setup.me.id)
        #expect(granted.map(\.sessionId) == ["b"])
        #expect(try setup.store.lockEvents(after: 0, for: "a").map(\.kind) == [.forceReleased])
        #expect(try setup.store.lockEvents(after: 0, for: "b").map(\.kind) == [.granted])
    }

    @Test func endingAChatReleasesItsLocksAndLeavesItsQueues() throws {
        let setup = try setup()
        _ = try setup.store.acquireLock(setup.request("qa-ios", "a"))
        _ = try setup.store.acquireLock(setup.request("merge mobicart-be", "b"))
        _ = try setup.store.acquireLock(setup.request("merge mobicart-be", "a", issue: 1))
        _ = try setup.store.acquireLock(setup.request("qa-ios", "c", issue: 2))

        let result = try setup.store.releaseLocks(forSession: "a")
        #expect(result.released == ["qa-ios"])
        #expect(result.left == ["merge mobicart-be"])
        #expect(result.granted.map(\.sessionId) == ["c"])
        #expect(try setup.queue("merge mobicart-be").isEmpty)
    }

    @Test func theTasksHistoryRecordsEachStepWithoutPingingChats() throws {
        let setup = try setup()
        let head = try setup.store.feedHead()
        _ = try setup.store.acquireLock(LockRequest(resource: "qa-web", issue: setup.issues[0].identifier, sessionId: "a", sessionTitle: "Checkout QA"))
        _ = try setup.store.acquireLock(setup.request("qa-web", "b", issue: 1))
        try setup.store.releaseLock("qa-web", sessionId: "a", resultNote: "All green")

        let first = try setup.store.comments(on: setup.issues[0].identifier).map(\.body)
        #expect(first.first == "Lock qa-web granted to ENG-1 (chat Checkout QA).")
        #expect(first.last?.hasPrefix("Lock qa-web released by ENG-1 (chat Checkout QA) after") == true)
        #expect(first.last?.hasSuffix("Result: All green") == true)
        let second = try setup.store.comments(on: setup.issues[1].identifier).map(\.body)
        #expect(second.first?.contains("is waiting for lock qa-web, position 1. Held by ENG-1 (chat Checkout QA).") == true)
        #expect(second.last?.hasPrefix("Lock qa-web granted to ENG-2 (chat b) after waiting") == true)

        // Written by a system member, so agent pings, which report only the user's changes, stay quiet.
        #expect(try setup.store.feed(after: head, memberKinds: [.user]).events.isEmpty)
    }

    @Test func unknownLocksTeachTheNames() throws {
        let setup = try setup()
        do {
            _ = try setup.store.acquireLock(setup.request("qa-webb", "a"))
            Issue.record("Expected a miss")
        } catch let TrackaroError.noMatch(entity, _, options) {
            #expect(entity == "lock")
            #expect(options.contains("qa-web"))
        }
        #expect(isGranted(try setup.store.acquireLock(setup.request("QA-WEB", "a"))), "names ignore case")
    }

    @Test func newResourcesAndConflictsAreData() throws {
        let setup = try setup()
        try setup.store.defineLockResource("staging-db", conflictsWith: ["merge mobicart-be"])
        _ = try setup.store.acquireLock(setup.request("merge mobicart-be", "a"))
        #expect(position(try setup.store.acquireLock(setup.request("staging-db", "b", issue: 1))) == 1)
        #expect(throws: TrackaroError.self) { try setup.store.deleteLockResource("staging-db") }
        try setup.store.leaveLockQueue("staging-db", sessionId: "b")
        try setup.store.deleteLockResource("staging-db")
        #expect(!(try setup.store.lockResources().map(\.name).contains("staging-db")))
    }

    @Test func badgesShowWhatEachIssueHoldsAndWaitsFor() throws {
        let setup = try setup()
        _ = try setup.store.acquireLock(setup.request("qa-web", "a"))
        _ = try setup.store.acquireLock(setup.request("qa-ios", "b", issue: 1))
        let badges = try setup.store.issueLockBadges()
        #expect(badges[setup.issues[0].id] == IssueLockBadge(held: ["qa-web"]))
        #expect(badges[setup.issues[1].id] == IssueLockBadge(waiting: ["qa-ios"]))
        #expect(badges[setup.issues[2].id] == nil)
    }

    @Test func durationsReadNaturally() {
        #expect(TrackaroStore.duration(42) == "42 s")
        #expect(TrackaroStore.duration(12 * 60 + 5) == "12 min")
        #expect(TrackaroStore.duration(2 * 3600 + 5 * 60) == "2 h 5 min")
    }
}
