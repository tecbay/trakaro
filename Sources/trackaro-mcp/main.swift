import Foundation
import MCP
import TrackaroCore
import TrackaroMCP

/// `trackaro-mcp`: the Trackaro MCP server over stdio, for Claude Code, Cursor and any other MCP client.
///
/// It opens the same database as the app. Both can run at once; the app picks up changes made here.
/// Everything except the MCP protocol goes to stderr, because stdout belongs to the protocol.

let usage = """
    Usage: trackaro-mcp [--database PATH] [--read-only] [--agent-name NAME]

      --database PATH    SQLite file to open. Default: $TRACKARO_DATABASE, then
                         ~/Library/Application Support/Trackaro/trackaro.sqlite
      --read-only        Expose only tools that read.
      --agent-name NAME  Name to record changes under. Default: derived from the client, e.g. "Claude Code".
      --version          Print the version and exit.

    Claude Code:  claude mcp add trackaro -- \(CommandLine.arguments.first ?? "trackaro-mcp")
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("trackaro-mcp: \(message)\n".utf8))
    exit(1)
}

var databasePath = ProcessInfo.processInfo.environment["TRACKARO_DATABASE"]
var options = TrackaroMCPServer.Options()
var remaining = CommandLine.arguments.dropFirst().makeIterator()
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
    case "--version":
        print(TrackaroMCPServer.version)
        exit(0)
    case "--help", "-h":
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(0)
    default:
        fail("unknown argument \(argument)\n\(usage)")
    }
}

do {
    let url = try databasePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? TrackaroStore.defaultURL()
    let store = try TrackaroStore.open(at: url)
    let server = try await TrackaroMCPServer.start(store: store, options: options, transport: StdioTransport())
    await server.waitUntilCompleted()
} catch {
    fail(String(describing: error))
}
