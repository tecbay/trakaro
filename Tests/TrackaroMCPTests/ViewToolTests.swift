import Foundation
import MCP
import Testing
@testable import TrackaroCore
@testable import TrackaroMCP

@Suite("Saved view tools")
struct ViewToolTests {
    @Test func agentsSaveSearchAndDeleteViews() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_issue", ["title": "Fix login", "state": "Todo", "priority": "urgent"])
        try await harness.call("create_issue", ["title": "Write docs", "state": "Todo", "priority": "low"])
        try await harness.call("create_issue", ["title": "Ship login", "state": "Done", "priority": "urgent"])

        let saved = try await harness.call("save_view", [
            "name": "Ready for agent", "category": "open", "priority": "urgent", "layout": "board",
        ])
        #expect(saved["matching_issues"]?.intValue == 1)
        #expect(saved["replaced"]?.boolValue == false)
        #expect(saved["layout"]?.stringValue == "board")
        #expect(saved["filter"]?["priority"]?.strings == ["urgent"])

        let workspace = try await harness.call("get_workspace")
        #expect(workspace["views"]?.pluck("name") == ["Ready for agent"])

        let inView = try await harness.call("search_issues", ["view": "ready for agent"])
        #expect(inView["issues"]?.pluck("identifier") == ["ENG-1"])
        let narrowed = try await harness.call("search_issues", ["view": "Ready for agent", "query": "docs"])
        #expect(narrowed["issues"]?.pluck("identifier") == [])

        let replaced = try await harness.call("save_view", ["name": "READY FOR AGENT", "query": "login"])
        #expect(replaced["replaced"]?.boolValue == true)
        #expect(replaced["name"]?.stringValue == "Ready for agent")
        #expect(replaced["matching_issues"]?.intValue == 2)
        #expect(replaced["layout"]?.stringValue == "board")

        let view = try harness.store.view("Ready for agent")
        let agent = try #require(try harness.store.snapshot().members.first { $0.kind == .agent })
        #expect(try harness.store.changes(since: 0).last { $0.model == "savedView" }?.memberId == agent.id)
        #expect(view.issueFilter.text == "login")

        let missing = try await harness.failure("search_issues", ["view": "Nope"])
        #expect(missing.contains("Ready for agent"))
        try await harness.call("delete_view", ["name": "Ready for agent"])
        #expect(try harness.store.views().isEmpty)
    }
}
