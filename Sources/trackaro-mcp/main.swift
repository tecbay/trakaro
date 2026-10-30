import Foundation
import MCP
import TrackaroCore
import TrackaroMCP

/// `trackaro-mcp`: the Trackaro MCP server over stdio, plus two small commands that let agents hear about
/// changes the user makes in the app.
///
/// It opens the same database as the app. Both can run at once; the app picks up changes made here.
/// In server mode stdout belongs to the protocol, so everything else goes to stderr.

let usage = """
    Usage:
      trackaro-mcp [--database PATH] [--read-only] [--agent-name NAME] [--channel]
          Run the MCP server over stdio.
          --channel   Also act as a Claude Code channel: push the user's changes into the session.
                      Start Claude Code with: claude --dangerously-load-development-channels server:trackaro

      trackaro-mcp watch [--database PATH] [--all] [--interval SECONDS]
          Print one line per change the user makes, as they happen. For Claude Code's Monitor tool.

      trackaro-mcp pending --state FILE [--format text|claude-stop|claude-prompt|cursor-stop] [--database PATH] [--all]
          Print what the user changed since the last call, in a hook's output format, and remember the position.

      --all       Include changes made by agents, not only by the user.
      --database  SQLite file. Default: $TRACKARO_DATABASE, then ~/Library/Application Support/Trackaro/trackaro.sqlite
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("trackaro-mcp: \(message)\n".utf8))
    exit(1)
}

func output(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

enum Mode {
    case server, watch, pending
}

var arguments = Array(CommandLine.arguments.dropFirst())
var mode = Mode.server
if let first = arguments.first, !first.hasPrefix("-") {
    switch first {
    case "watch": mode = .watch
    case "pending": mode = .pending
    default: fail("unknown command \(first)\n\(usage)")
    }
    arguments.removeFirst()
}

var databasePath = ProcessInfo.processInfo.environment["TRACKARO_DATABASE"]
var options = TrackaroMCPServer.Options()
var includeAgents = false
var stateFile: String?
var format = AgentFeed.Format.text
var interval = 0.5
var remaining = arguments.makeIterator()
while let argument = remaining.next() {
    switch argument {
    case "--database":
        guard let path = remaining.next() else { fail("--database needs a path") }
        databasePath = path
    case "--read-only":
        options.readOnly = true
    case "--agent-name":
        guard let name = remaining.next() else { fail("--agent-name needs a name") }
        options.agentName = name
    case "--channel":
        options.channel = true
    case "--all":
        includeAgents = true
    case "--state":
        guard let path = remaining.next() else { fail("--state needs a file path") }
        stateFile = path
    case "--format":
        guard let name = remaining.next(), let value = AgentFeed.Format(rawValue: name) else {
            fail("--format must be one of \(AgentFeed.Format.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        format = value
    case "--interval":
        guard let value = remaining.next().flatMap(Double.init), value >= 0.1 else { fail("--interval needs seconds, at least 0.1") }
        interval = value
    case "--version":
        output(TrackaroMCPServer.version)
        exit(0)
    case "--help", "-h":
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(0)
    default:
        fail("unknown argument \(argument)\n\(usage)")
    }
}

func expand(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}

do {
    let store = try TrackaroStore.open(at: try databasePath.map(expand) ?? TrackaroStore.defaultURL())
    let feed = AgentFeed(store: store, humansOnly: !includeAgents)
    switch mode {
    case .server:
        let server = try await TrackaroMCPServer.start(store: store, options: options, transport: StdioTransport())
        await server.waitUntilCompleted()
    case .watch:
        var cursor = try store.feedHead()
        while true {
            try await Task.sleep(for: .seconds(interval))
            let result = try feed.changes(after: cursor)
            cursor = result.cursor
            for line in result.lines { output(line) }
        }
    case .pending:
        guard let stateFile else { fail("pending needs --state FILE to remember its position") }
        if let text = try feed.pending(stateFile: expand(stateFile), format: format) { output(text) }
    }
} catch {
    fail(String(describing: error))
}
