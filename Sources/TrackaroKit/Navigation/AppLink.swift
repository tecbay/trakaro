import Foundation

/// A `trackaro://` deep link. Agents can print these for the user to click, and launchers can script the app.
///
///     trackaro://issue/ENG-42
///     trackaro://my-issues
///     trackaro://agent-activity
///     trackaro://team/ENG            (or /ENG/active, /ENG/backlog)
///     trackaro://view/Ready%20for%20agent   (a saved view, by name or id)
///     trackaro://projects            trackaro://project/mobile-launch   (slug, name or id)
///     trackaro://cycles/ENG          trackaro://cycle/ENG/current       (or a cycle number)
///     trackaro://command/palette     (any AppCommand)
public enum AppLink: Equatable, Sendable {
    case issue(String)
    case myIssues
    case agentActivity
    case team(key: String, page: String?)
    case view(String)
    case projects
    case project(String)
    case cycles(teamKey: String)
    case cycle(teamKey: String, cycle: String)
    case command(AppCommand)

    public static let scheme = "trackaro"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }.compactMap { $0.removingPercentEncoding }
        switch (host, parts.count) {
        case ("issue", 1):
            self = .issue(parts[0])
        case ("my-issues", 0):
            self = .myIssues
        case ("agent-activity", 0):
            self = .agentActivity
        case ("team", 1):
            self = .team(key: parts[0], page: nil)
        case ("team", 2):
            self = .team(key: parts[0], page: parts[1].lowercased())
        case ("projects", 0):
            self = .projects
        case ("project", 1):
            self = .project(parts[0])
        case ("cycles", 1):
            self = .cycles(teamKey: parts[0])
        case ("cycle", 2):
            self = .cycle(teamKey: parts[0], cycle: parts[1].lowercased())
        case ("view", 1):
            self = .view(parts[0])
        case ("command", 1):
            guard let command = AppCommand(rawValue: parts[0]) else { return nil }
            self = .command(command)
        default:
            return nil
        }
    }

    public static func issueURL(_ identifier: String) -> URL? {
        URL(string: "\(scheme)://issue/\(identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier)")
    }
}
