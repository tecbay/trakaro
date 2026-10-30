import Foundation
import Logging
import MCP

/// Wraps a transport to make the server a Claude Code channel: a server that can push events into the running
/// session so Claude takes a turn without the user typing. Channels are a research preview in Claude Code.
///
/// The Swift SDK has no field for experimental capabilities, so this adds `experimental["claude/channel"]` to
/// the initialize result on its way out, and sends `notifications/claude/channel` messages directly.
/// Protocol: https://code.claude.com/docs/en/channels-reference
actor ChannelTransport: Transport {
    static let capability = "claude/channel"
    static let method = "notifications/claude/channel"

    private let inner: any Transport
    let logger = Logger(label: "trackaro.channel", factory: { _ in SwiftLogNoOpLogHandler() })

    init(wrapping inner: any Transport) {
        self.inner = inner
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ data: Data) async throws {
        try await inner.send(Self.addingChannelCapability(to: data))
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let inner = self.inner
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in await inner.receive() { continuation.yield(message) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pushes one event into the session. Meta keys must be letters, digits and underscores; others are dropped
    /// by Claude Code, so they are filtered here too.
    func push(_ content: String, meta: [String: String]) async throws {
        let safeMeta = meta.filter { key, _ in key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": Self.method,
            "params": ["content": content, "meta": safeMeta],
        ]
        try await inner.send(try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]))
    }

    /// Adds the channel capability to an initialize result; returns every other message unchanged.
    static func addingChannelCapability(to data: Data) -> Data {
        guard var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var result = message["result"] as? [String: Any],
              result["serverInfo"] != nil, result["protocolVersion"] != nil,
              var capabilities = result["capabilities"] as? [String: Any] else { return data }
        var experimental = capabilities["experimental"] as? [String: Any] ?? [:]
        experimental[capability] = [String: Any]()
        capabilities["experimental"] = experimental
        result["capabilities"] = capabilities
        message["result"] = result
        return (try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])) ?? data
    }
}
