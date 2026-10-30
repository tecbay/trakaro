import Foundation

/// Domain errors. The MCP layer and the UI map these to messages; nothing else should be thrown across the store API.
public enum TrackaroError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `entity` is a model name such as "issue"; `reference` is what the caller asked for.
    case notFound(entity: String, reference: String)
    /// A name that matched nothing, with the names that would have matched. Lets an agent correct itself in one step.
    case noMatch(entity: String, reference: String, options: [String])
    case invalid(field: String, message: String)
    /// The caller's expectation no longer matches stored state, or a reference matched several rows.
    case conflict(message: String, candidates: [String])

    public var description: String {
        switch self {
        case let .notFound(entity, reference):
            "No \(entity) matches \"\(reference)\"."
        case let .noMatch(entity, reference, options):
            options.isEmpty
                ? "No \(entity) matches \"\(reference)\", and there are none yet."
                : "No \(entity) matches \"\(reference)\". Options: \(options.joined(separator: ", "))."
        case let .invalid(field, message):
            "\(field): \(message)"
        case let .conflict(message, candidates):
            candidates.isEmpty ? message : "\(message) Candidates: \(candidates.joined(separator: ", "))."
        }
    }
}
