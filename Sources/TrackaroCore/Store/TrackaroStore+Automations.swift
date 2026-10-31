import Foundation
import GRDB

/// What the automations editor submits. The team comes from the state, so a rule cannot point at a column of
/// another team.
public struct AutomationInput: Sendable, Equatable {
    public var name: String
    public var stateId: String
    public var directory: String
    public var prompt: String
    public var command: String
    public var enabled: Bool

    public init(
        name: String, stateId: String, directory: String, prompt: String = Automation.defaultPrompt,
        command: String = Automation.claudeCommand, enabled: Bool = true
    ) {
        self.name = name
        self.stateId = stateId
        self.directory = directory
        self.prompt = prompt
        self.command = command
        self.enabled = enabled
    }
}

extension TrackaroStore {
    public func automations() throws -> [Automation] {
        try writer.read { db in try Automation.order(Column("createdAt")).fetchAll(db) }
    }

    @discardableResult
    public func createAutomation(_ input: AutomationInput, by memberId: String) throws -> Automation {
        let input = try Self.validated(input)
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            let state = try requireState(db, input.stateId)
            let automation = Automation(
                id: newId(), name: input.name, teamId: state.teamId, stateId: state.id, directory: input.directory,
                prompt: input.prompt, command: input.command, enabled: input.enabled, createdAt: now, updatedAt: now
            )
            try automation.insert(db)
            try recordChange(db, model: "automation", id: automation.id, action: .insert, by: memberId, at: now, snapshot: automation)
            return automation
        }
    }

    @discardableResult
    public func updateAutomation(_ id: String, _ input: AutomationInput, by memberId: String) throws -> Automation {
        let input = try Self.validated(input)
        return try writer.write { db in
            let now = clock()
            _ = try requireMember(db, memberId)
            guard var automation = try Automation.fetchOne(db, key: id) else {
                throw TrackaroError.notFound(entity: "automation", reference: id)
            }
            let state = try requireState(db, input.stateId)
            automation.name = input.name
            automation.teamId = state.teamId
            automation.stateId = state.id
            automation.directory = input.directory
            automation.prompt = input.prompt
            automation.command = input.command
            automation.enabled = input.enabled
            automation.updatedAt = now
            try automation.update(db)
            try recordChange(db, model: "automation", id: automation.id, action: .update, by: memberId, at: now, snapshot: automation)
            return automation
        }
    }

    public func deleteAutomation(_ id: String, by memberId: String) throws {
        try writer.write { db in
            _ = try requireMember(db, memberId)
            guard try Automation.deleteOne(db, key: id) else { throw TrackaroError.notFound(entity: "automation", reference: id) }
            try recordChange(db, model: "automation", id: id, action: .delete, by: memberId, at: clock(), snapshot: Automation?.none)
        }
    }

    // MARK: Runs

    @discardableResult
    public func startRun(automationId: String, issueId: String, logPath: String) throws -> AutomationRun {
        try writer.write { db in
            let now = clock()
            let run = AutomationRun(id: newId(), automationId: automationId, issueId: issueId, status: .running,
                                    logPath: logPath, exitCode: nil, startedAt: now, finishedAt: nil)
            try run.insert(db)
            try recordChange(db, model: "automationRun", id: run.id, action: .insert, by: nil, at: now, snapshot: run)
            return run
        }
    }

    @discardableResult
    public func finishRun(_ id: String, status: AutomationRunStatus, exitCode: Int?) throws -> AutomationRun {
        guard status.isFinished else { throw TrackaroError.invalid(field: "status", message: "A finished run needs a final status.") }
        return try writer.write { db in
            let now = clock()
            guard var run = try AutomationRun.fetchOne(db, key: id) else { throw TrackaroError.notFound(entity: "automation run", reference: id) }
            run.status = status
            run.exitCode = exitCode
            run.finishedAt = now
            try run.update(db)
            try recordChange(db, model: "automationRun", id: run.id, action: .update, by: nil, at: now, snapshot: run)
            return run
        }
    }

    /// Runs for one issue, newest first.
    public func runs(issueId: String, limit: Int = 20) throws -> [AutomationRun] {
        try writer.read { db in
            try AutomationRun.filter(Column("issueId") == issueId)
                .order(Column("startedAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func runningRuns() throws -> [AutomationRun] {
        try writer.read { db in try AutomationRun.filter(Column("status") == AutomationRunStatus.running.rawValue).fetchAll(db) }
    }

    /// Marks runs left running by an app that quit as interrupted. Their processes ended with it.
    @discardableResult
    public func interruptRunningRuns() throws -> Int {
        let running = try runningRuns()
        for run in running { try finishRun(run.id, status: .interrupted, exitCode: nil) }
        return running.count
    }

    private static func validated(_ input: AutomationInput) throws -> AutomationInput {
        var input = input
        input.name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        input.directory = input.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        input.command = input.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.name.isEmpty else { throw TrackaroError.invalid(field: "name", message: "An automation needs a name.") }
        guard input.directory.hasPrefix("/") else {
            throw TrackaroError.invalid(field: "directory", message: "Choose the folder the command runs in.")
        }
        guard !input.command.isEmpty else { throw TrackaroError.invalid(field: "command", message: "An automation needs a command.") }
        guard !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrackaroError.invalid(field: "prompt", message: "An automation needs a prompt.")
        }
        return input
    }
}
