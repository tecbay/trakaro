import Foundation
import Testing
@testable import TrackaroCore
@testable import TrackaroKit

@Suite("Column automations")
struct AutomationTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AutomationRunner.Event] = []
        func append(_ event: AutomationRunner.Event) { lock.withLock { items.append(event) } }
        var count: Int { lock.withLock { items.count } }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trackaro-automation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntilFinished(_ store: TrackaroStore, issueId: String) async throws -> AutomationRun {
        for _ in 0..<200 {
            if let run = try store.runs(issueId: issueId).first, run.status.isFinished { return run }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TrackaroError.invalid(field: "run", message: "The run did not finish in time.")
    }

    @Test func storeValidatesRulesAndRecordsRuns() throws {
        let fixture = try KitFixture()
        let store = fixture.store
        let ready = try fixture.state("Todo")
        #expect(throws: TrackaroError.self) {
            try store.createAutomation(AutomationInput(name: "x", stateId: ready.id, directory: "relative/path"), by: fixture.me.id)
        }
        let rule = try store.createAutomation(AutomationInput(name: " Ready ", stateId: ready.id, directory: "/tmp"), by: fixture.me.id)
        #expect(rule.name == "Ready")
        #expect(rule.teamId == fixture.team.id)
        #expect(rule.command == Automation.claudeCommand)

        let issue = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "A"), by: fixture.me.id)
        let run = try store.startRun(automationId: rule.id, issueId: issue.id, logPath: "/tmp/a.log")
        #expect(try store.runningRuns().map(\.id) == [run.id])
        #expect(try store.interruptRunningRuns() == 1)
        #expect(try store.runs(issueId: issue.id).first?.status == .interrupted)

        try store.deleteAutomation(rule.id, by: fixture.me.id)
        #expect(try store.automations().isEmpty)
        #expect(try store.runs(issueId: issue.id).isEmpty)
    }

    @Test func onlyTheUsersMovesIntoTheColumnTrigger() throws {
        let fixture = try KitFixture()
        let store = fixture.store
        let todo = try fixture.state("Todo")
        let started = try fixture.state("In Progress")
        let claude = try store.agent(named: "Claude Code")
        let rule = try store.createAutomation(AutomationInput(name: "Ready", stateId: todo.id, directory: "/tmp"), by: fixture.me.id)
        let paused = try store.createAutomation(AutomationInput(name: "Off", stateId: todo.id, directory: "/tmp", enabled: false), by: fixture.me.id)
        let head = try store.feedHead()

        let moved = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Moved by me"), by: fixture.me.id)
        _ = try store.updateIssue(moved.id, IssuePatch(stateId: todo.id), by: fixture.me.id)
        _ = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Created in Todo", stateId: todo.id), by: fixture.me.id)
        let byAgent = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Agent"), by: claude.id)
        _ = try store.updateIssue(byAgent.id, IssuePatch(stateId: todo.id), by: claude.id)
        let passedThrough = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "Passed through"), by: fixture.me.id)
        _ = try store.updateIssue(passedThrough.id, IssuePatch(stateId: todo.id), by: fixture.me.id)
        _ = try store.updateIssue(passedThrough.id, IssuePatch(stateId: started.id), by: fixture.me.id)

        let events = try store.feed(after: head).events
        let planned = AutomationMatcher.runs(for: events, automations: try store.automations(), running: [])
        #expect(planned.map(\.issue.title) == ["Moved by me", "Created in Todo"])
        #expect(planned.allSatisfy { $0.automation.id == rule.id && $0.automation.id != paused.id })

        let busy = try store.startRun(automationId: rule.id, issueId: moved.id, logPath: "/tmp/x.log")
        let again = AutomationMatcher.runs(for: events, automations: try store.automations(), running: [busy])
        #expect(again.map(\.issue.title) == ["Created in Todo"])
    }

    @Test func promptFillsPlaceholders() throws {
        let fixture = try KitFixture()
        let issue = try fixture.store.createIssue(NewIssue(teamId: fixture.team.id, title: "Fix it", description: "Steps", stateId: try fixture.state("Todo").id), by: fixture.me.id)
        let text = AutomationPrompt.render("{identifier} {title} in {state} of {team}: {description} {url}", issue: issue, snapshot: try fixture.store.snapshot())
        #expect(text == "ENG-1 Fix it in Todo of Engineering: Steps trackaro://issue/ENG-1")
    }

    @Test func runnerRunsTheCommandWithIssueTextOnlyInTheEnvironment() async throws {
        let fixture = try KitFixture()
        let store = fixture.store
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let todo = try fixture.state("Todo")
        _ = try store.createAutomation(AutomationInput(
            name: "Echo", stateId: todo.id, directory: directory.path, prompt: "Work on {identifier}: {title}",
            command: #"printf '%s|%s|%s' "$TRACKARO_ISSUE" "$TRACKARO_PROMPT" "$TRACKARO_DATABASE" > out.txt"#
        ), by: fixture.me.id)
        let events = Events()
        let runner = AutomationRunner(store: store, logDirectory: directory.appendingPathComponent("logs"), databasePath: "/db/test.sqlite",
                                      shell: ["/bin/sh", "-c"], onEvent: { events.append($0) })
        try await runner.start()

        let hostile = "$(touch pwned) `touch pwned2`"
        let issue = try store.createIssue(NewIssue(teamId: fixture.team.id, title: hostile, stateId: todo.id), by: fixture.me.id)
        let launched = try await runner.tick()
        #expect(launched.count == 1)
        #expect(try await runner.tick().isEmpty)

        let run = try await waitUntilFinished(store, issueId: issue.id)
        #expect(run.status == .succeeded)
        #expect(run.exitCode == 0)
        let output = try String(contentsOf: directory.appendingPathComponent("out.txt"), encoding: .utf8)
        #expect(output == "ENG-1|Work on ENG-1: \(hostile)|/db/test.sqlite")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned2").path))
        let log = try String(contentsOfFile: run.logPath, encoding: .utf8)
        #expect(log.contains("Trackaro automation “Echo” for ENG-1"))
        #expect(log.contains("run succeeded, exit code 0"))
        #expect(events.count == 2)
    }

    @Test func failuresMissingFoldersAndStopsAreRecorded() async throws {
        let fixture = try KitFixture()
        let store = fixture.store
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let todo = try fixture.state("Todo")
        let runner = AutomationRunner(store: store, logDirectory: directory.appendingPathComponent("logs"), databasePath: nil,
                                      shell: ["/bin/sh", "-c"], onEvent: { _ in })
        let issue = try store.createIssue(NewIssue(teamId: fixture.team.id, title: "A", stateId: todo.id), by: fixture.me.id)

        let failing = try store.createAutomation(AutomationInput(name: "Fail", stateId: todo.id, directory: directory.path, command: "echo nope >&2; exit 3"), by: fixture.me.id)
        _ = try await runner.launch(PlannedRun(automation: failing, issue: issue))
        let failed = try await waitUntilFinished(store, issueId: issue.id)
        #expect(failed.status == .failed)
        #expect(failed.exitCode == 3)
        #expect(try String(contentsOfFile: failed.logPath, encoding: .utf8).contains("nope"))

        let missing = try store.createAutomation(AutomationInput(name: "Missing", stateId: todo.id, directory: "/nonexistent/trackaro"), by: fixture.me.id)
        let missingRun = try await runner.launch(PlannedRun(automation: missing, issue: issue))
        #expect(missingRun.status == .failed)

        let slow = try store.createAutomation(AutomationInput(name: "Slow", stateId: todo.id, directory: directory.path, command: "exec sleep 30"), by: fixture.me.id)
        let slowRun = try await runner.launch(PlannedRun(automation: slow, issue: issue))
        await runner.stop(runId: slowRun.id)
        let stopped = try await waitUntilFinished(store, issueId: issue.id)
        #expect(stopped.id == slowRun.id)
        #expect(stopped.status == .stopped)
        #expect(await runner.activeRunIds.isEmpty)
    }
}
