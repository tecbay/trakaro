import Foundation
import Testing
import TrackaroCore
@testable import TrackaroKit

@Suite("Connecting agents")
struct AgentConnectorTests {
    /// A temporary home folder, so no test can touch the real agent configs.
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("trackaro-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to path: String, in home: URL) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func makeExecutable(_ script: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The object a percent-encoded query value decodes to.
    private func queryItem(_ name: String, in url: URL) throws -> String {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return try #require(components.queryItems?.first { $0.name == name }?.value)
    }

    // MARK: Finding the server

    @Test("Prefers the server inside the app")
    func findsBundledServer() throws {
        let home = try makeHome()
        let app = home.appendingPathComponent("Applications/Trackaro.app")
        let helper = app.appendingPathComponent("Contents/Helpers/trackaro-mcp")
        try makeExecutable("#!/bin/sh\n", at: helper)
        try makeExecutable("#!/bin/sh\n", at: home.appendingPathComponent(".local/bin/trackaro-mcp"))
        #expect(try AgentConnector.serverPath(appBundle: app, home: home) == helper.path)
    }

    @Test("A development build falls back to ~/.local/bin")
    func fallsBackToInstalledServer() throws {
        let home = try makeHome()
        let installed = home.appendingPathComponent(".local/bin/trackaro-mcp")
        try makeExecutable("#!/bin/sh\n", at: installed)
        #expect(try AgentConnector.serverPath(appBundle: home.appendingPathComponent("Debug/Trackaro.app"), home: home) == installed.path)
    }

    @Test("No server anywhere explains how to get one")
    func missingServerTeaches() throws {
        let home = try makeHome()
        #expect {
            try AgentConnector.serverPath(appBundle: home.appendingPathComponent("Trackaro.app"), home: home)
        } throws: { error in
            String(describing: error).contains("make-dmg")
        }
    }

    // MARK: Status

    @Test("Reads each tool's file and key", arguments: AgentClient.allCases)
    func connectedStatus(client: AgentClient) throws {
        let home = try makeHome()
        let connector = AgentConnector(serverPath: "/x/trackaro-mcp", home: home)
        #expect(connector.status(of: client) == .notConnected)
        let server = home.appendingPathComponent("server")
        try Data().write(to: server)
        try write(#"{"\#(client.config.key)":{"trackaro":{"command":"\#(server.path)"}}}"#, to: client.config.path, in: home)
        #expect(connector.status(of: client) == .connected)
    }

    @Test("VS Code keeps servers under its own key")
    func vsCodeKey() {
        #expect(AgentClient.vsCode.config.key == "servers")
        #expect(AgentClient.cursor.config.key == "mcpServers")
    }

    @Test("A server file that is gone reads as broken")
    func brokenStatus() throws {
        let home = try makeHome()
        try write(#"{"mcpServers":{"trackaro":{"command":"/gone/trackaro-mcp"}}}"#, to: ".cursor/mcp.json", in: home)
        let connector = AgentConnector(serverPath: "/x/trackaro-mcp", home: home)
        #expect(connector.status(of: .cursor) == .broken(path: "/gone/trackaro-mcp"))
    }

    @Test("A config that cannot be read is not connected")
    func unreadableStatus() throws {
        let home = try makeHome()
        try write("{ not json", to: ".cursor/mcp.json", in: home)
        #expect(AgentConnector(serverPath: "/x", home: home).status(of: .cursor) == .notConnected)
    }

    // MARK: Install links

    @Test("The Cursor link carries the config as base64 JSON")
    func cursorLink() throws {
        let connector = AgentConnector(serverPath: "/Applications/My Apps/Trackaro.app/Contents/Helpers/trackaro-mcp")
        let link = try #require(connector.installLink(for: .cursor))
        #expect(link.absoluteString.hasPrefix("cursor://anysphere.cursor-deeplink/mcp/install?"))
        #expect(try queryItem("name", in: link) == "trackaro")
        let decoded = try #require(Data(base64Encoded: try queryItem("config", in: link)))
        let config = try json(decoded)
        #expect(config["command"] as? String == connector.serverPath)
        #expect((config["args"] as? [String])?.isEmpty == true)
    }

    @Test("The VS Code link carries percent-encoded JSON")
    func vsCodeLink() throws {
        let connector = AgentConnector(serverPath: "/Applications/My Apps/Trackaro.app/Contents/Helpers/trackaro-mcp")
        let link = try #require(connector.installLink(for: .vsCode))
        let prefix = "vscode:mcp/install?"
        #expect(link.absoluteString.hasPrefix(prefix))
        let encoded = String(link.absoluteString.dropFirst(prefix.count))
        #expect(!encoded.contains("{") && !encoded.contains(" ") && !encoded.contains("/"))
        let config = try json(Data(try #require(encoded.removingPercentEncoding).utf8))
        #expect(config["name"] as? String == "trackaro")
        #expect(config["command"] as? String == connector.serverPath)
    }

    @Test("Only Cursor and VS Code have install links")
    func noLinkForClaude() {
        let connector = AgentConnector(serverPath: "/x")
        #expect(connector.installLink(for: .claudeCode) == nil)
        #expect(connector.installLink(for: .claudeDesktop) == nil)
    }

    // MARK: Claude Desktop

    @Test("Claude Desktop keeps every other setting and server, and a backup")
    func desktopMergePreserves() throws {
        let home = try makeHome()
        let original = #"{"preferences":{"sidebarMode":"chat","count":3,"on":true},"mcpServers":{"rea":{"command":"/bin/rea","args":["--x"]}},"other":"keep"}"#
        let path = AgentClient.claudeDesktop.config.path
        try write(original, to: path, in: home)
        let connector = AgentConnector(serverPath: "/x/trackaro-mcp", home: home)
        try connector.connectClaudeDesktop()

        let file = home.appendingPathComponent(path)
        let root = try json(Data(contentsOf: file))
        #expect(root["other"] as? String == "keep")
        let preferences = try #require(root["preferences"] as? [String: Any])
        #expect(preferences["sidebarMode"] as? String == "chat")
        #expect(preferences["count"] as? Int == 3)
        #expect(preferences["on"] as? Bool == true)
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect((servers["rea"] as? [String: Any])?["command"] as? String == "/bin/rea")
        #expect((servers["trackaro"] as? [String: Any])?["command"] as? String == "/x/trackaro-mcp")
        #expect(try String(contentsOf: file.appendingPathExtension("bak"), encoding: .utf8) == original)
    }

    @Test("Claude Desktop's file is created when it does not exist")
    func desktopCreatesFile() throws {
        let home = try makeHome()
        let connector = AgentConnector(serverPath: "/x/trackaro-mcp", home: home)
        try connector.connectClaudeDesktop()
        let root = try json(Data(contentsOf: home.appendingPathComponent(AgentClient.claudeDesktop.config.path)))
        #expect((root["mcpServers"] as? [String: Any])?["trackaro"] != nil)
    }

    @Test("Invalid JSON is left untouched", arguments: ["{ not json", #"{"mcpServers":[]}"#, "[1,2]"])
    func desktopRefusesBadFile(contents: String) throws {
        let home = try makeHome()
        let path = AgentClient.claudeDesktop.config.path
        try write(contents, to: path, in: home)
        let connector = AgentConnector(serverPath: "/x/trackaro-mcp", home: home)
        #expect(throws: TrackaroError.self) { try connector.connectClaudeDesktop() }
        #expect(try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) == contents)
    }

    // MARK: Claude Code

    /// A fake `claude` that records its arguments, one per line, then exits with `code`.
    private func fakeClaude(in home: URL, exit code: Int = 0) throws -> URL {
        let log = home.appendingPathComponent("claude-calls.txt")
        try makeExecutable("""
            #!/bin/sh
            for arg in "$@"; do printf '%s\\n' "$arg" >> "\(log.path)"; done
            printf -- '--end--\\n' >> "\(log.path)"
            [ \(code) -eq 0 ] || echo "server already exists" >&2
            exit \(code)
            """, at: home.appendingPathComponent(".local/bin/claude"))
        return log
    }

    private func calls(_ log: URL) throws -> String {
        try String(contentsOf: log, encoding: .utf8)
    }

    @Test("Claude Code gets a user-scope server, with the path as one argument")
    func claudeCodeAdd() async throws {
        let home = try makeHome()
        let log = try fakeClaude(in: home)
        let path = "/Applications/My $(touch pwned) Apps/trackaro-mcp"
        let connector = AgentConnector(serverPath: path, home: home, shell: ["/bin/sh", "-c"])
        try await connector.connectClaudeCode()
        #expect(try calls(log) == "mcp\nadd\n--scope\nuser\ntrackaro\n--\n\(path)\n--end--\n")
    }

    @Test("A broken entry is removed first")
    func claudeCodeReplacesBroken() async throws {
        let home = try makeHome()
        let log = try fakeClaude(in: home)
        try write(#"{"mcpServers":{"trackaro":{"command":"/gone/trackaro-mcp"}}}"#, to: ".claude.json", in: home)
        let connector = AgentConnector(serverPath: "/x/trackaro-mcp", home: home, shell: ["/bin/sh", "-c"])
        try await connector.connectClaudeCode()
        #expect(try calls(log) == "mcp\nremove\n--scope\nuser\ntrackaro\n--end--\nmcp\nadd\n--scope\nuser\ntrackaro\n--\n/x/trackaro-mcp\n--end--\n")
    }

    @Test("A failure reports what claude said")
    func claudeCodeFailure() async throws {
        let home = try makeHome()
        _ = try fakeClaude(in: home, exit: 1)
        let connector = AgentConnector(serverPath: "/x/trackaro-mcp", home: home, shell: ["/bin/sh", "-c"])
        await #expect {
            try await connector.connectClaudeCode()
        } throws: { error in
            String(describing: error).contains("server already exists")
        }
    }

    @Test("Finds the claude command")
    func claudeCodeDetection() async throws {
        let home = try makeHome()
        _ = try fakeClaude(in: home)
        #expect(await AgentConnector(serverPath: "/x", home: home, shell: ["/bin/sh", "-c"]).claudeCodeIsInstalled())
    }
}
