import Foundation
import MCP
import Testing
@testable import TrackaroCore
@testable import TrackaroMCP

@Suite("Agent feed and hooks")
struct AgentFeedTests {
    private func makeStore() throws -> (TrackaroStore, Member, Team) {
        let store = try TrackaroStore.inMemory()
        let me = try store.localUser()
        let team = try store.createTeam(key: "ENG", name: "Engineering", by: me.id)
        return (store, me, team)
    }

    @Test func linesDescribeWhatTheUserDid() throws {
        let (store, me, team) = try makeStore()
        let claude = try store.agent(named: "Claude Code")
        let head = try store.feedHead()
        let issue = try store.createIssue(NewIssue(teamId: team.id, title: "Ship the board"), by: claude.id)
        let inProgress = try #require(try store.states(teamId: team.id).first { $0.name == "In Progress" })
        _ = try store.updateIssue(issue.id, IssuePatch(stateId: inProgress.id), by: me.id)
        try store.addComment(to: issue.id, body: "Please pick\nthis up", by: me.id)

        let lines = try AgentFeed(store: store).changes(after: head).lines
        #expect(lines == [
            "ENG-1 “Ship the board”: the user moved it from Backlog to In Progress",
            "ENG-1 “Ship the board”: the user commented: “Please pick this up”",
        ])
        #expect(try AgentFeed(store: store, humansOnly: false).changes(after: head).lines.count == 3)
    }

    @Test func hookFormatsMatchWhatEachToolExpects() throws {
        let lines = ["ENG-1 “A”: the user moved it from Todo to In Progress"]
        let stop = try #require(AgentFeed.render(lines, as: .claudeStop))
        let stopJSON = try #require(try JSONSerialization.jsonObject(with: Data(stop.utf8)) as? [String: Any])
        #expect(stopJSON["decision"] as? String == "block")
        #expect((stopJSON["reason"] as? String)?.contains("ENG-1") == true)

        let prompt = try #require(AgentFeed.render(lines, as: .claudePrompt))
        let promptJSON = try #require(try JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
        let specific = try #require(promptJSON["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "UserPromptSubmit")
        #expect((specific["additionalContext"] as? String)?.contains("ENG-1") == true)

        let cursor = try #require(AgentFeed.render(lines, as: .cursorStop))
        #expect(cursor.contains("\"followup_message\""))

        #expect(AgentFeed.render([], as: .claudeStop) == nil)
        #expect(AgentFeed.render([], as: .claudePrompt) == nil)
        #expect(AgentFeed.render([], as: .cursorStop) == "{}")
    }

    @Test func pendingRemembersItsPositionAndSkipsHistoryOnFirstRun() throws {
        let (store, me, team) = try makeStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trackaro-feed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("cursor")
        let feed = AgentFeed(store: store)

        _ = try store.createIssue(NewIssue(teamId: team.id, title: "Old news"), by: me.id)
        #expect(try feed.pending(stateFile: state, format: .text) == nil)

        let issue = try store.createIssue(NewIssue(teamId: team.id, title: "Fresh"), by: me.id)
        _ = try store.updateIssue(issue.id, IssuePatch(priority: .urgent), by: me.id)
        let text = try #require(try feed.pending(stateFile: state, format: .text))
        #expect(text.contains("ENG-2 “Fresh”: the user created the issue"))
        #expect(text.contains("set priority to Urgent"))
        #expect(!text.contains("Old news"))
        #expect(try feed.pending(stateFile: state, format: .text) == nil)
    }

    @Test func channelCapabilityIsAddedOnlyToTheInitializeResult() throws {
        let initialize = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"trackaro","version":"0.1.0"},"capabilities":{"tools":{}}}}"#
        let patched = ChannelTransport.addingChannelCapability(to: Data(initialize.utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: patched) as? [String: Any])
        let capabilities = try #require((object["result"] as? [String: Any])?["capabilities"] as? [String: Any])
        #expect((capabilities["experimental"] as? [String: Any])?["claude/channel"] != nil)
        #expect(capabilities["tools"] != nil)

        let toolResult = #"{"jsonrpc":"2.0","id":2,"result":{"content":[],"capabilities":{}}}"#
        #expect(ChannelTransport.addingChannelCapability(to: Data(toolResult.utf8)) == Data(toolResult.utf8))
    }

    @Test func channelModePushesTheUsersChangesIntoTheSession() async throws {
        let (store, me, team) = try makeStore()
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        try await TrackaroMCPServer.start(
            store: store, options: .init(channel: true, channelInterval: .milliseconds(50)), transport: serverSide
        )
        try await clientSide.connect()
        let messages = await clientSide.receive()
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#
        try await clientSide.send(Data(initialize.utf8))

        var sawCapability = false
        var pushed: [String: Any]?
        var changed = false
        for try await data in messages {
            let message = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            if let result = message["result"] as? [String: Any], let capabilities = result["capabilities"] as? [String: Any] {
                sawCapability = (capabilities["experimental"] as? [String: Any])?["claude/channel"] != nil
                try await clientSide.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
                try await Task.sleep(for: .milliseconds(120))
                _ = try store.createIssue(NewIssue(teamId: team.id, title: "Moved by the user"), by: me.id)
                changed = true
            }
            if changed, message["method"] as? String == "notifications/claude/channel" {
                pushed = message["params"] as? [String: Any]
                break
            }
        }
        #expect(sawCapability)
        let params = try #require(pushed)
        #expect((params["content"] as? String)?.contains("ENG-1 “Moved by the user”: the user created the issue") == true)
        let meta = try #require(params["meta"] as? [String: String])
        #expect(meta["issue"] == "ENG-1")
        #expect(meta["source"] == "trackaro")
    }

    @Test func channelInstructionsOnlyAppearInChannelMode() {
        #expect(Instructions.text(readOnly: false, channel: true).contains("trackaro channel"))
        #expect(!Instructions.text(readOnly: false).contains("trackaro channel"))
    }
}
