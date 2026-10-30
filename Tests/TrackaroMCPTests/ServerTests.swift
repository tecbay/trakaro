import Foundation
import MCP
import Testing
@testable import TrackaroCore
@testable import TrackaroMCP

@Suite("MCP server surface")
struct ServerSurfaceTests {
    @Test func advertisesToolsWithAnnotationsAndStrictSchemas() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        let (tools, _) = try await harness.client.listTools()
        #expect(tools.count == TrackaroMCPServer.allTools.count)
        #expect(Set(tools.map(\.name)).count == tools.count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) needs a description")
            #expect(tool.inputSchema["type"]?.stringValue == "object")
            #expect(tool.inputSchema["additionalProperties"]?.boolValue == false)
            #expect(tool.annotations.readOnlyHint != nil)
        }
        let readOnly = Set(tools.filter { $0.annotations.readOnlyHint == true }.map(\.name))
        #expect(readOnly == ["get_workspace", "search_issues", "get_issues", "list_comments", "get_issue_history", "list_projects", "list_cycles", "cycle_progress"])
        #expect(tools.first { $0.name == "remove_relation" }?.annotations.destructiveHint == true)
    }

    @Test func instructionsPointAgentsAtGetWorkspace() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        let instructions = try #require(harness.initialize.instructions)
        #expect(instructions.contains("get_workspace"))
        #expect(instructions.contains("\"self\" is you"))
        #expect(harness.initialize.serverInfo.name == "trackaro")
    }

    @Test func readOnlyModeHidesAndRefusesWrites() async throws {
        let harness = try await Harness.start(readOnly: true)
        defer { Task { await harness.stop() } }
        let (tools, _) = try await harness.client.listTools()
        #expect(tools.allSatisfy { $0.annotations.readOnlyHint == true })
        let error = try await harness.failure("create_issue", ["title": "Nope"])
        #expect(error.contains("read-only"))
        #expect(try harness.store.queryIssues(IssueQuery()).issues.isEmpty)
        let (prompts, _) = try await harness.client.listPrompts()
        #expect(prompts.map(\.name) == ["standup"])
    }

    @Test func unknownToolsAndArgumentsAreExplained() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        #expect(try await harness.failure("delete_everything").contains("Available: get_workspace"))
        let error = try await harness.failure("create_issue", ["titel": "Typo"])
        #expect(error.contains("Unknown argument"))
        #expect(error.contains("title"))
        #expect(try await harness.failure("create_issue", [:]).contains("title: Required."))
        try await harness.call("create_issue", ["title": "Real"])
        #expect(try await harness.failure("update_issue", ["issue": "ENG-1", "estimate": "lots"]).contains("Expected a whole number"))
    }

    @Test("Agent names come from the client", arguments: [
        ("claude-code", nil, "Claude Code"),
        ("cursor-vscode", nil, "Cursor"),
        ("claude-ai", nil, "Claude"),
        ("my_agent-tool", nil, "My Agent Tool"),
        ("anything", "Zed Assistant", "Zed Assistant"),
    ] as [(String, String?, String)])
    func agentNames(name: String, title: String?, expected: String) {
        #expect(TrackaroMCPServer.agentName(for: Client.Info(name: name, version: "1", title: title)) == expected)
    }
}

@Suite("MCP issue workflow")
struct IssueWorkflowTests {
    @Test func createFindStartAndFinishAnIssueByName() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_label", ["name": "bug", "color": "#E5484D"])

        let created = try await harness.call("create_issue", [
            "title": "Fix login redirect", "description": "Users land on a blank page.",
            "state": "Todo", "priority": "high", "labels": ["bug"], "assignee": "me", "due_date": "2027-02-01",
        ])
        #expect(created["identifier"]?.stringValue == "ENG-1")
        #expect(created["state"]?.stringValue == "Todo")
        #expect(created["priority"]?.stringValue == "high")
        #expect(created["labels"]?.strings == ["bug"])
        #expect(created["assignee"]?.stringValue == "Me")
        #expect(created["creator"]?.stringValue == "Claude Code")

        let found = try await harness.call("search_issues", ["query": "login", "category": "open", "assignee": "me"])
        #expect(found["count"]?.intValue == 1)
        #expect(found["issues"]?.pluck("identifier") == ["ENG-1"])

        let started = try await harness.call("update_issue", ["issue": "eng-1", "state": "In Progress", "assignee": "self"])
        #expect(started["changed"]?.strings == ["state", "assignee"])
        #expect(started["issue"]?["assignee"]?.stringValue == "Claude Code")

        try await harness.call("add_comment", ["issue": "ENG-1", "body": "Fixed the redirect and added a test."])
        let comments = try await harness.call("list_comments", ["issue": "ENG-1"])
        #expect(comments["comments"]?[0]?["author"]?.stringValue == "Claude Code")

        let history = try await harness.call("get_issue_history", ["issue": "ENG-1"])
        let stateChange = history["history"]?.arrayValue?.first { $0["field"]?.stringValue == "state" }
        #expect(stateChange?["from"]?.stringValue == "Todo")
        #expect(stateChange?["to"]?.stringValue == "In Progress")
        #expect(stateChange?["by"]?.stringValue == "Claude Code")

        let stored = try harness.store.issue("ENG-1")
        #expect(stored.startedAt != nil)
    }

    @Test func nullClearsAndOmittedFieldsStay() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_issue", ["title": "Sized", "estimate": 3, "assignee": "me"])
        let cleared = try await harness.call("update_issue", ["issue": "ENG-1", "assignee": .null])
        #expect(cleared["changed"]?.strings == ["assignee"])
        #expect(cleared["issue"]?["assignee"] == nil)
        #expect(cleared["issue"]?["estimate"]?.intValue == 3)
        let noop = try await harness.call("update_issue", ["issue": "ENG-1", "estimate": 3])
        #expect(noop["changed"]?.strings == [])
    }

    @Test func misspelledNamesListTheOptions() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_issue", ["title": "Anything"])
        let state = try await harness.failure("update_issue", ["issue": "ENG-1", "state": "Doing"])
        #expect(state.contains("No state in ENG matches \"Doing\". Options: Triage, Backlog, Todo, In Progress"))
        let label = try await harness.failure("update_issue", ["issue": "ENG-1", "add_labels": ["nope"]])
        #expect(label.contains("there are none yet"))
        let member = try await harness.failure("update_issue", ["issue": "ENG-1", "assignee": "Bob"])
        #expect(member.contains("Options: me, self"))
        #expect(try await harness.failure("get_issue_history", ["issue": "ENG-99"]).contains("No issue matches \"ENG-99\""))
    }

    @Test func categoryNamesWorkWhenUnambiguous() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_issue", ["title": "Ship", "state": "started"])
        #expect(try harness.store.issue("ENG-1").startedAt != nil)
        let todo = try await harness.call("update_issue", ["issue": "ENG-1", "state": "unstarted"])
        #expect(todo["issue"]?["state"]?.stringValue == "Todo")
        let byName = try await harness.call("update_issue", ["issue": "ENG-1", "state": "canceled"])
        #expect(byName["issue"]?["state"]?.stringValue == "Canceled")
    }

    @Test func subIssuesAreValidatedBeforeAnyWrite() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_issue", ["title": "Epic"])
        let rejected = try await harness.failure("create_sub_issues", ["parent": "ENG-1", "issues": [
            ["title": "Good one"], ["title": "Bad one", "state": "Nowhere"],
        ]])
        #expect(rejected.contains("issues[1]"))
        #expect(try harness.store.queryIssues(IssueQuery()).issues.count == 1)

        let created = try await harness.call("create_sub_issues", ["parent": "ENG-1", "issues": [
            ["title": "Design", "estimate": 2], ["title": "Build", "estimate": 5], ["title": "Test", "priority": "low"],
        ]])
        #expect(created["issues"]?.pluck("identifier") == ["ENG-2", "ENG-3", "ENG-4"])
        #expect(created["issues"]?.pluck("parent") == ["ENG-1", "ENG-1", "ENG-1"])

        let detail = try await harness.call("get_issues", ["issues": ["ENG-1", "ENG-404"]])
        #expect(detail["issues"]?[0]?["sub_issues"]?.pluck("identifier") == ["ENG-2", "ENG-3", "ENG-4"])
        #expect(detail["not_found"]?.strings == ["ENG-404"])
    }

    @Test func bulkUpdateResolvesNamesPerTeamAndRefusesPartialInput() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_team", ["key": "OPS", "name": "Operations"])
        try await harness.call("create_issue", ["title": "Eng work", "team": "ENG"])
        try await harness.call("create_issue", ["title": "Ops work", "team": "OPS"])

        let partial = try await harness.call("bulk_update_issues", ["issues": ["ENG-1", "ENG-77"], "state": "Done"])
        #expect(partial["failed"]?.pluck("issue") == ["ENG-77"])
        #expect(partial["updated"]?.arrayValue?.isEmpty == true)
        #expect(try harness.store.issue("ENG-1").completedAt == nil)

        let done = try await harness.call("bulk_update_issues", ["issues": ["ENG-1", "OPS-1"], "state": "Done", "priority": "low"])
        #expect(done["updated"]?.pluck("issue") == ["ENG-1", "OPS-1"])
        #expect(try harness.store.issue("OPS-1").completedAt != nil)
    }

    @Test func moveAcrossTeamsKeepsTheOldIdentifierWorking() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_team", ["key": "OPS", "name": "Operations"])
        try await harness.call("create_issue", ["title": "Wrong team", "team": "ENG", "state": "In Progress"])
        let moved = try await harness.call("move_issue", ["issue": "ENG-1", "team": "OPS"])
        #expect(moved["issue"]?["identifier"]?.stringValue == "OPS-1")
        #expect(moved["issue"]?["state"]?.stringValue == "In Progress")
        #expect(moved["previous_identifier"]?.stringValue == "ENG-1")
        let byOldName = try await harness.call("get_issues", ["issues": ["ENG-1"]])
        #expect(byOldName["issues"]?[0]?["identifier"]?.stringValue == "OPS-1")
    }

    @Test func reorderWithinAColumn() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        for title in ["One", "Two", "Three"] { try await harness.call("create_issue", ["title": .string(title)]) }
        try await harness.call("move_issue", ["issue": "ENG-3", "after": "ENG-1"])
        let order = try await harness.call("search_issues", ["state": "Backlog"])
        #expect(order["issues"]?.pluck("identifier") == ["ENG-2", "ENG-1", "ENG-3"])
    }

    @Test func relationsDuplicatesAndArchive() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        for title in ["API", "Client", "Client again"] { try await harness.call("create_issue", ["title": .string(title)]) }
        let linked = try await harness.call("set_relation", ["issue": "ENG-1", "type": "blocks", "related": "ENG-2"])
        #expect(linked["relations"]?.pluck("issue") == ["ENG-2"])
        let blocked = try await harness.call("get_issues", ["issues": ["ENG-2"]])
        #expect(blocked["issues"]?[0]?["blocked"]?.boolValue == true)
        #expect(blocked["issues"]?[0]?["relations"]?.pluck("type") == ["blocked_by"])

        let duplicate = try await harness.call("mark_duplicate", ["issue": "ENG-3", "duplicate_of": "ENG-2"])
        #expect(duplicate["issue"]?["state"]?.stringValue == "Duplicate")
        #expect(duplicate["issue"]?["category"]?.stringValue == "canceled")

        try await harness.call("archive_issue", ["issue": "ENG-3"])
        let open = try await harness.call("search_issues", [:])
        #expect(open["issues"]?.pluck("identifier").contains("ENG-3") == false)
        try await harness.call("archive_issue", ["issue": "ENG-3", "archived": false])
        #expect(try harness.store.issue("ENG-3").archivedAt == nil)
    }

    @Test func searchPagesWithCursor() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        for index in 1...5 { try await harness.call("create_issue", ["title": .string("Task \(index)")]) }
        let first = try await harness.call("search_issues", ["order": "created", "limit": 2])
        #expect(first["issues"]?.pluck("identifier") == ["ENG-5", "ENG-4"])
        let cursor = try #require(first["next_cursor"]?.stringValue)
        let second = try await harness.call("search_issues", ["order": "created", "limit": 2, "cursor": .string(cursor)])
        #expect(second["issues"]?.pluck("identifier") == ["ENG-3", "ENG-2"])
        let empty = try await harness.call("search_issues", ["query": "zebra"])
        #expect(empty["count"]?.intValue == 0)
        #expect(empty["issues"]?.arrayValue == [])
    }

    @Test func overriddenAgentNameIsRecorded() async throws {
        let harness = try await Harness.start(agentName: "Claude (frontend)")
        defer { Task { await harness.stop() } }
        let created = try await harness.call("create_issue", ["title": "Tagged"])
        #expect(created["creator"]?.stringValue == "Claude (frontend)")
        let workspace = try await harness.call("get_workspace")
        #expect(workspace["you"]?.stringValue == "Claude (frontend)")
    }
}

@Suite("MCP planning, resources and prompts")
struct PlanningResourcePromptTests {
    @Test func cyclesAndProgress() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        let cycle = try await harness.call("create_cycle", ["name": "Sprint 1"])
        #expect(cycle["active"]?.boolValue == true)
        try await harness.call("create_issue", ["title": "Planned", "cycle": "active", "estimate": 3, "state": "Done"])
        try await harness.call("create_issue", ["title": "Also planned", "cycle": "1", "estimate": 5])
        let progress = try await harness.call("cycle_progress")
        #expect(progress["issues"]?.intValue == 2)
        #expect(progress["completed"]?.intValue == 1)
        #expect(progress["points_total"]?.intValue == 8)
        #expect(progress["percent_complete"]?.intValue == 50)
        let inCycle = try await harness.call("search_issues", ["cycle": "active"])
        #expect(inCycle["count"]?.intValue == 2)
        let workspace = try await harness.call("get_workspace")
        #expect(workspace["teams"]?[0]?["active_cycle"]?["number"]?.intValue == 1)
    }

    @Test func projectsAndMilestones() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_project", ["name": "Mobile Launch", "target_date": "2027-06-01"])
        try await harness.call("create_milestone", ["project": "mobile-launch", "name": "Beta"])
        let issue = try await harness.call("create_issue", ["title": "Beta build", "milestone": "Beta"])
        #expect(issue["project"]?.stringValue == "Mobile Launch")
        #expect(issue["milestone"]?.stringValue == "Beta")
        let projects = try await harness.call("list_projects")
        #expect(projects["projects"]?[0]?["milestones"]?.strings == ["Beta"])
        let inProject = try await harness.call("search_issues", ["project": "Mobile Launch"])
        #expect(inProject["count"]?.intValue == 1)
    }

    @Test func resourcesReadWorkspaceAndIssues() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_issue", ["title": "Readable"])
        let (resources, _) = try await harness.client.listResources()
        #expect(resources.map(\.uri) == ["trackaro://workspace", "trackaro://cycles/active"])
        let (templates, _) = try await harness.client.listResourceTemplates()
        #expect(templates.map(\.uriTemplate) == ["trackaro://issue/{identifier}"])

        let workspace = try await harness.client.readResource(uri: "trackaro://workspace")
        #expect(workspace.first?.text?.contains("\"key\":\"ENG\"") == true)
        let issue = try await harness.client.readResource(uri: "trackaro://issue/ENG-1")
        #expect(issue.first?.text?.contains("\"title\":\"Readable\"") == true)
        await #expect(throws: (any Error).self) {
            _ = try await harness.client.readResource(uri: "trackaro://issue/ENG-9")
        }
    }

    @Test func promptsCarryCurrentData() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        try await harness.call("create_issue", ["title": "Untriaged thing", "state": "Triage"])
        try await harness.call("create_issue", ["title": "Active thing", "state": "In Progress"])
        let (prompts, _) = try await harness.client.listPrompts()
        #expect(prompts.map(\.name) == ["standup", "triage", "plan_work"])

        let standup = try await harness.client.getPrompt(name: "standup")
        guard case let .text(standupText) = standup.messages.first?.content else { throw Harness.ToolFailure(description: "no text") }
        #expect(standupText.contains("ENG-2"))

        let triage = try await harness.client.getPrompt(name: "triage", arguments: ["team": "ENG"])
        guard case let .text(triageText) = triage.messages.first?.content else { throw Harness.ToolFailure(description: "no text") }
        #expect(triageText.contains("Untriaged thing"))
        #expect(!triageText.contains("Active thing"))

        let plan = try await harness.client.getPrompt(name: "plan_work", arguments: ["goal": "Dark mode"])
        guard case let .text(planText) = plan.messages.first?.content else { throw Harness.ToolFailure(description: "no text") }
        #expect(planText.contains("Goal: Dark mode"))
        await #expect(throws: (any Error).self) { _ = try await harness.client.getPrompt(name: "plan_work") }
    }
}
