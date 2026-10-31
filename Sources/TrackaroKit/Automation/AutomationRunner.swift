import Foundation
import TrackaroCore

/// Watches the change feed and runs column automations as local processes.
///
/// Each run is `zsh -l -c <command>` in the automation's folder, so the user's login PATH finds `claude`. Issue
/// text only ever reaches the command through environment variables (`TRACKARO_PROMPT`, `TRACKARO_ISSUE`,
/// `TRACKARO_TITLE`, `TRACKARO_URL`): a title such as `$(rm -rf ~)` is data inside a variable, never shell. Output
/// goes to a log file per run, and the run's status is recorded in the database.
///
/// `TRACKARO_DATABASE` is passed on, so an agent started against a test database writes to that database too.
public actor AutomationRunner {
    public enum Event: Sendable {
        case started(AutomationRun, Automation, Issue)
        case finished(AutomationRun, Automation, Issue)
    }

    private let store: TrackaroStore
    private let logDirectory: URL
    private let databasePath: String?
    private let shell: [String]
    private let onEvent: @Sendable (Event) -> Void
    private var cursor: FeedCursor?
    private var processes: [String: Process] = [:]
    private var logs: [String: FileHandle] = [:]
    private var stopping: Set<String> = []
    private var context: [String: (Automation, Issue)] = [:]

    public init(
        store: TrackaroStore, logDirectory: URL, databasePath: String?, shell: [String] = ["/bin/zsh", "-l", "-c"],
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.store = store
        self.logDirectory = logDirectory
        self.databasePath = databasePath
        self.shell = shell
        self.onEvent = onEvent
    }

    /// Starts watching from now. Runs a previous app left marked running are recorded as interrupted.
    public func start() throws {
        try store.interruptRunningRuns()
        cursor = try store.feedHead()
    }

    /// Stops reacting to the feed, for the length of a restore. Running processes carry on.
    public func suspend() {
        cursor = nil
    }

    /// Reacts to the feed again, from now.
    public func resume() throws {
        cursor = try store.feedHead()
    }

    /// Reads new feed events and launches what they trigger. Cheap when nothing changed: two indexed lookups.
    @discardableResult
    public func tick() throws -> [AutomationRun] {
        guard let current = cursor else { return [] }
        let (events, next) = try store.feed(after: current, memberKinds: [.user])
        cursor = next
        guard !events.isEmpty else { return [] }
        let planned = AutomationMatcher.runs(for: events, automations: try store.automations(), running: try store.runningRuns())
        return try planned.map(launch)
    }

    /// Starts one run now, whatever the feed says. Also used by "Run now" in the app.
    @discardableResult
    public func launch(_ planned: PlannedRun) throws -> AutomationRun {
        let automation = planned.automation
        let issue = planned.issue
        let snapshot = try store.snapshot()
        let prompt = AutomationPrompt.render(automation.prompt, issue: issue, snapshot: snapshot)

        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent("\(issue.identifier)-\(Self.stamp())-\(UUID().uuidString.prefix(6)).log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data(Self.header(automation, issue: issue, prompt: prompt).utf8))
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()

        let run = try store.startRun(automationId: automation.id, issueId: issue.id, logPath: logURL.path)
        context[run.id] = (automation, issue)
        logs[run.id] = log

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: automation.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            log.write(Data("Trackaro: the folder \(automation.directory) does not exist.\n".utf8))
            return try finish(run.id, status: .failed, exitCode: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell[0])
        process.arguments = Array(shell.dropFirst()) + [automation.command]
        process.currentDirectoryURL = URL(fileURLWithPath: automation.directory)
        process.environment = environment(prompt: prompt, issue: issue)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        let runId = run.id
        process.terminationHandler = { [weak self] finished in
            let code = Int(finished.terminationStatus)
            Task { [weak self] in try? await self?.exited(runId, code: code) }
        }
        do {
            try process.run()
        } catch {
            log.write(Data("Trackaro: could not start the command: \(error.localizedDescription)\n".utf8))
            return try finish(run.id, status: .failed, exitCode: nil)
        }
        processes[run.id] = process
        onEvent(.started(run, automation, issue))
        return run
    }

    /// Asks a running process to stop. The run is recorded as stopped once it exits.
    public func stop(runId: String) {
        guard let process = processes[runId] else { return }
        stopping.insert(runId)
        process.terminate()
    }

    public func stopAll() {
        for id in processes.keys { stop(runId: id) }
    }

    public var activeRunIds: [String] { Array(processes.keys) }

    private func exited(_ runId: String, code: Int) throws {
        processes[runId] = nil
        let status: AutomationRunStatus = stopping.contains(runId) ? .stopped : code == 0 ? .succeeded : .failed
        stopping.remove(runId)
        _ = try finish(runId, status: status, exitCode: code)
    }

    private func finish(_ runId: String, status: AutomationRunStatus, exitCode: Int?) throws -> AutomationRun {
        let run = try store.finishRun(runId, status: status, exitCode: exitCode)
        logs[runId]?.write(Data("\nTrackaro: run \(status.rawValue)\(exitCode.map { ", exit code \($0)" } ?? "").\n".utf8))
        try? logs[runId]?.close()
        logs[runId] = nil
        if let (automation, issue) = context.removeValue(forKey: runId) {
            onEvent(.finished(run, automation, issue))
        }
        return run
    }

    private func environment(prompt: String, issue: Issue) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        environment["TRACKARO_PROMPT"] = prompt
        environment["TRACKARO_ISSUE"] = issue.identifier
        environment["TRACKARO_TITLE"] = issue.title
        environment["TRACKARO_URL"] = AppLink.issueURL(issue.identifier)?.absoluteString
        if let databasePath { environment["TRACKARO_DATABASE"] = databasePath }
        return environment
    }

    private static func header(_ automation: Automation, issue: Issue, prompt: String) -> String {
        """
        Trackaro automation “\(automation.name)” for \(issue.identifier) “\(issue.title)”
        Folder: \(automation.directory)
        Command: \(automation.command)
        Prompt:
        \(prompt)

        ---

        """
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

