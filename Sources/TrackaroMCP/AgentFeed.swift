import Foundation
import MCP
import TrackaroCore
import TrackaroKit

/// Turns the change feed into what agents read: one line per change, and the exact output formats that
/// Claude Code and Cursor hooks expect. Shared by `trackaro-mcp watch`, `trackaro-mcp pending` and channel push.
public struct AgentFeed: Sendable {
    public enum Format: String, CaseIterable, Sendable {
        /// One line per change.
        case text
        /// Claude Code Stop hook: keeps Claude working when the user changed something.
        case claudeStop = "claude-stop"
        /// Claude Code UserPromptSubmit hook: adds the changes as context to the next prompt.
        case claudePrompt = "claude-prompt"
        /// Cursor stop hook: sends the changes as a follow-up message.
        case cursorStop = "cursor-stop"
    }

    public let store: TrackaroStore
    /// Only changes made by the person using the app, not by agents. The usual setting: an agent reacting to
    /// other agents can loop, and it already knows what it did itself.
    public let humansOnly: Bool

    public init(store: TrackaroStore, humansOnly: Bool = true) {
        self.store = store
        self.humansOnly = humansOnly
    }

    public func changes(after cursor: FeedCursor, excludingMember: String? = nil) throws -> (lines: [String], events: [FeedEvent], cursor: FeedCursor) {
        let (events, next) = try store.feed(after: cursor, memberKinds: humansOnly ? [.user] : nil, excludingMember: excludingMember)
        guard !events.isEmpty else { return ([], [], next) }
        let snapshot = try store.snapshot()
        let parents = events.compactMap { event -> String? in
            if case let .activity(activity) = event.kind, activity.field == .parent { return Self.jsonString(activity.toValue) }
            return nil
        }
        let formatter = ActivityFormatter(snapshot: snapshot, identifiers: try store.identifiers(forIssueIds: parents))
        return (events.map { Self.line($0, formatter: formatter) }, events, next)
    }

    /// `ENG-4 “Command palette ranking”: the user moved it from Todo to In Progress`
    static func line(_ event: FeedEvent, formatter: ActivityFormatter) -> String {
        let actor = event.member.kind == .user ? "the user" : event.member.name
        let subject = "\(event.issue.identifier) “\(event.issue.title)”"
        switch event.kind {
        case let .activity(activity):
            return "\(subject): \(actor) \(formatter.describe(activity))"
        case let .comment(comment):
            let body = comment.body.count > 280 ? String(comment.body.prefix(279)) + "…" : comment.body
            return "\(subject): \(actor) commented: “\(body.replacingOccurrences(of: "\n", with: " "))”"
        }
    }

    /// The hook or terminal output for these lines, or nil when there is nothing to say.
    /// Cursor's stop hook always wants a JSON object, so it gets `{}` when nothing changed.
    public static func render(_ lines: [String], as format: Format) -> String? {
        if lines.isEmpty { return format == .cursorStop ? "{}" : nil }
        let summary = "Changes in Trackaro since your last turn:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
        let advice = "\nIf any of these affect your work, act on them with the Trackaro tools: pick up an issue the user moved into a started state, answer comments addressed to you, stop work on anything moved back or canceled. Otherwise, carry on."
        switch format {
        case .text:
            return lines.joined(separator: "\n")
        case .claudeStop:
            return json(["decision": "block", "reason": summary + advice])
        case .claudePrompt:
            return json(["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": summary + advice]])
        case .cursorStop:
            return json(["followup_message": summary + advice])
        }
    }

    /// One-shot check for hooks: reads the cursor from `stateFile`, reports what changed since, saves the new
    /// cursor. The first run only records the current position, so a new hook does not replay history.
    public func pending(stateFile: URL, format: Format) throws -> String? {
        let saved = (try? String(contentsOf: stateFile, encoding: .utf8)).flatMap(FeedCursor.init)
        guard let saved else {
            try save(try store.feedHead(), to: stateFile)
            return Self.render([], as: format)
        }
        let result = try changes(after: saved)
        try save(result.cursor, to: stateFile)
        return Self.render(result.lines, as: format)
    }

    private func save(_ cursor: FeedCursor, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cursor.description.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonString(_ json: String?) -> String? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }
}
