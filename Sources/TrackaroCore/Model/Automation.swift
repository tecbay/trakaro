import Foundation
import GRDB

/// A column automation: when the user moves an issue into `stateId`, run `command` in `directory` with the
/// rendered `prompt` in the environment. Only the person using the app can create these; MCP has no tool for them,
/// because a rule is a shell command.
public struct Automation: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "automation"
    public var id: String
    public var name: String
    public var teamId: String
    public var stateId: String
    /// Absolute path of the folder the command runs in, usually a repository.
    public var directory: String
    /// Prompt template. `{identifier}`, `{title}`, `{state}`, `{team}`, `{url}` and `{description}` are filled in.
    public var prompt: String
    /// Shell command, run by `zsh -l -c`. The rendered prompt is in `$TRACKARO_PROMPT`; never splice issue text in.
    public var command: String
    public var enabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public static let claudeCommand = #"claude -p "$TRACKARO_PROMPT" --permission-mode acceptEdits --allowedTools mcp__trackaro"#

    public static let defaultPrompt = """
        A Trackaro automation started you because the user moved {identifier} “{title}” to {state}.

        Read the issue with get_issues and do the work in this repository. Move it to In Progress when you start. \
        When you finish, add a comment saying what you changed and how you verified it, then move it to In Review. \
        If something blocks you, comment with what you need and leave it where it is.
        """
}

public enum AutomationRunStatus: String, Codable, CaseIterable, Sendable {
    case running, succeeded, failed, stopped
    /// Still marked running when the app started again, so its process was lost with the old app.
    case interrupted

    public var isFinished: Bool { self != .running }
}

/// One execution of an automation for one issue. The full output is in the log file.
public struct AutomationRun: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "automationRun"
    public var id: String
    public var automationId: String
    public var issueId: String
    public var status: AutomationRunStatus
    public var logPath: String
    public var exitCode: Int?
    public var startedAt: Date
    public var finishedAt: Date?
}
