import Foundation
import MCP
import Testing
@testable import TrackaroCore
@testable import TrackaroMCP

/// A real MCP client talking to a real Trackaro server over an in-memory transport.
struct Harness {
    let store: TrackaroStore
    let client: Client
    let server: Server
    let initialize: Initialize.Result
    let me: Member

    struct ToolFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func start(readOnly: Bool = false, clientName: String = "claude-code", agentName: String? = nil) async throws -> Harness {
        let store = try TrackaroStore.inMemory()
        let me = try store.localUser()
        try store.createTeam(key: "ENG", name: "Engineering", by: me.id)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = try await TrackaroMCPServer.start(
            store: store,
            options: TrackaroMCPServer.Options(readOnly: readOnly, agentName: agentName),
            transport: serverTransport
        )
        let client = Client(name: clientName, version: "1.0.0")
        let initialize = try await client.connect(transport: clientTransport)
        return Harness(store: store, client: client, server: server, initialize: initialize, me: me)
    }

    /// Calls a tool that must succeed and returns its parsed JSON.
    @discardableResult
    func call(_ tool: String, _ arguments: [String: Value] = [:]) async throws -> Value {
        let (text, isError) = try await raw(tool, arguments)
        if isError { throw ToolFailure(description: text) }
        return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
    }

    /// Calls a tool that must fail and returns its error text.
    func failure(_ tool: String, _ arguments: [String: Value] = [:]) async throws -> String {
        let (text, isError) = try await raw(tool, arguments)
        if !isError { throw ToolFailure(description: "Expected \(tool) to fail, got \(text)") }
        return text
    }

    private func raw(_ tool: String, _ arguments: [String: Value]) async throws -> (String, Bool) {
        let (content, isError) = try await client.callTool(name: tool, arguments: arguments)
        guard case let .text(text, _, _) = content.first else { throw ToolFailure(description: "No text content from \(tool)") }
        return (text, isError ?? false)
    }

    func stop() async {
        await client.disconnect()
        await server.stop()
    }
}

extension Value {
    subscript(_ key: String) -> Value? { objectValue?[key] }
    subscript(_ index: Int) -> Value? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    var strings: [String] { arrayValue?.compactMap(\.stringValue) ?? [] }

    func pluck(_ key: String) -> [String] {
        arrayValue?.compactMap { $0[key]?.stringValue } ?? []
    }
}
