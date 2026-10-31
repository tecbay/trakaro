import Foundation
import TrackaroCore

/// A tool that can run `trackaro-mcp` as an MCP server.
public enum AgentClient: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, claudeDesktop, cursor, vsCode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        case .vsCode: "VS Code"
        }
    }

    /// A URL scheme the tool handles, which shows it is installed. Claude Code and Claude Desktop are found another way.
    public var urlScheme: String? {
        switch self {
        case .cursor: "cursor"
        case .vsCode: "vscode"
        case .claudeCode, .claudeDesktop: nil
        }
    }

    /// The JSON file holding the tool's user-level servers, relative to the home folder, and the key they sit under.
    var config: (path: String, key: String) {
        switch self {
        case .claudeCode: (".claude.json", "mcpServers")
        case .claudeDesktop: ("Library/Application Support/Claude/claude_desktop_config.json", "mcpServers")
        case .cursor: (".cursor/mcp.json", "mcpServers")
        case .vsCode: ("Library/Application Support/Code/User/mcp.json", "servers")
        }
    }
}

public enum AgentConnectionStatus: Equatable, Sendable {
    case notConnected
    case connected
    /// Connected to a server file that no longer exists, usually because the app moved.
    case broken(path: String)
}

/// Connects agent tools to the `trackaro-mcp` inside this app.
///
/// The server's path only reaches the shell through an environment variable and is never spliced into the command
/// string, the same rule automations follow. Connecting never replaces an entry that still works, so custom flags
/// such as `--channel` survive.
public struct AgentConnector: Sendable {
    public static let serverName = "trackaro"

    public let serverPath: String
    let home: URL
    let shell: [String]

    public init(
        serverPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        shell: [String] = ["/bin/zsh", "-l", "-c"]
    ) {
        self.serverPath = serverPath
        self.home = home
        self.shell = shell
    }

    /// Finds the server: inside the app, or `~/.local/bin` for a development build that has none inside.
    public static func serverPath(appBundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let bundled = appBundle.appendingPathComponent("Contents/Helpers/trackaro-mcp").path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            guard !bundled.hasPrefix("/Volumes/"), !bundled.contains("/AppTranslocation/") else {
                throw TrackaroError.invalid(
                    field: "app location",
                    message: "Move Trackaro to Applications and reopen it first, so the connection keeps working."
                )
            }
            return bundled
        }
        let installed = home.appendingPathComponent(".local/bin/trackaro-mcp").path
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        throw TrackaroError.invalid(
            field: "server",
            message: "This build has no trackaro-mcp inside. Build the app with scripts/make-dmg.sh, or install the server to ~/.local/bin."
        )
    }

    // MARK: Status

    public func status(of client: AgentClient) -> AgentConnectionStatus {
        let file = home.appendingPathComponent(client.config.path)
        guard
            let data = try? Data(contentsOf: file),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let servers = root[client.config.key] as? [String: Any],
            let entry = servers[Self.serverName] as? [String: Any]
        else { return .notConnected }
        if let command = entry["command"] as? String, command.hasPrefix("/"), !FileManager.default.fileExists(atPath: command) {
            return .broken(path: command)
        }
        return .connected
    }

    // MARK: Connecting

    /// The link that asks Cursor or VS Code to install the server. They show their own confirmation.
    public func installLink(for client: AgentClient) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        switch client {
        case .cursor:
            guard
                let config = try? JSONSerialization.data(withJSONObject: ["command": serverPath, "args": [String]()], options: .sortedKeys),
                let encoded = config.base64EncodedString().addingPercentEncoding(withAllowedCharacters: allowed)
            else { return nil }
            return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=\(Self.serverName)&config=\(encoded)")
        case .vsCode:
            let object: [String: Any] = ["name": Self.serverName, "command": serverPath, "args": [String]()]
            guard
                let json = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
                let encoded = String(decoding: json, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: allowed)
            else { return nil }
            return URL(string: "vscode:mcp/install?\(encoded)")
        case .claudeCode, .claudeDesktop:
            return nil
        }
    }

    /// Whether the `claude` command exists in the user's login shell.
    public func claudeCodeIsInstalled() async -> Bool {
        (try? await run("command -v claude"))?.status == 0
    }

    /// Registers the server with Claude Code at user scope, replacing an entry whose server file is gone.
    public func connectClaudeCode() async throws {
        let add = #"claude mcp add --scope user "$TRACKARO_SERVER_NAME" -- "$TRACKARO_SERVER_PATH""#
        let command: String
        if case .broken = status(of: .claudeCode) {
            command = #"claude mcp remove --scope user "$TRACKARO_SERVER_NAME" >/dev/null 2>&1; "# + add
        } else {
            command = add
        }
        let result = try await run(command)
        guard result.status == 0 else {
            let reason = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TrackaroError.invalid(
                field: "Claude Code",
                message: reason.isEmpty ? "claude mcp add failed with exit code \(result.status)." : reason
            )
        }
    }

    /// Adds the server to Claude Desktop's config. Everything else in the file stays, and the old file is kept beside
    /// it as `.bak`. A file that is not valid JSON is left alone.
    public func connectClaudeDesktop() throws {
        let file = home.appendingPathComponent(AgentClient.claudeDesktop.config.path).resolvingSymlinksInPath()
        let existing = try? Data(contentsOf: file)
        let merged = try Self.merged(existing: existing, key: AgentClient.claudeDesktop.config.key, serverPath: serverPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing {
            try existing.write(to: file.appendingPathExtension("bak"), options: .atomic)
        }
        try merged.write(to: file, options: .atomic)
    }

    static func merged(existing: Data?, key: String, serverPath: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw TrackaroError.invalid(
                    field: "Claude Desktop config",
                    message: "claude_desktop_config.json is not valid JSON, so Trackaro left it alone. Fix the file and try again."
                )
            }
            root = parsed
        }
        var servers: [String: Any] = [:]
        if let value = root[key] {
            guard let existingServers = value as? [String: Any] else {
                throw TrackaroError.invalid(
                    field: "Claude Desktop config",
                    message: "\(key) in claude_desktop_config.json is not an object, so Trackaro left the file alone."
                )
            }
            servers = existingServers
        }
        servers[serverName] = ["command": serverPath, "args": [String]()]
        root[key] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Shell

    private func run(_ command: String) async throws -> (status: Int32, output: String) {
        var environment = ProcessInfo.processInfo.environment
        let extra = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        environment["TRACKARO_SERVER_NAME"] = Self.serverName
        environment["TRACKARO_SERVER_PATH"] = serverPath

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell[0])
        process.arguments = Array(shell.dropFirst()) + [command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TrackaroError.invalid(field: "shell", message: "Could not start the shell: \(error.localizedDescription)"))
            }
        }
    }
}
