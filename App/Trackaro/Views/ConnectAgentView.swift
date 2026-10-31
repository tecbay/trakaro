import AppKit
import SwiftUI
import TrackaroKit

/// Lists the agent tools on this Mac and connects each to the `trackaro-mcp` inside the app with one click.
struct ConnectAgentView: View {
    @Environment(\.dismiss) private var dismiss

    private static let claudeDesktopBundleId = "com.anthropic.claudefordesktop"

    @State private var connector: AgentConnector?
    @State private var setupError: String?
    @State private var statuses: [AgentClient: AgentConnectionStatus] = [:]
    @State private var installed: Set<AgentClient> = []
    @State private var notes: [AgentClient: Note] = [:]
    @State private var working: AgentClient?

    struct Note: Equatable {
        var text: String
        var isError = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect an agent").font(.title2.weight(.semibold))
                Text("Let your agent read and update your tasks. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            if let setupError {
                ContentUnavailableView("Cannot connect yet", systemImage: "exclamationmark.triangle", description: Text(setupError))
                    .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(AgentClient.allCases) { client in
                        row(client)
                        if client != AgentClient.allCases.last { Divider().padding(.leading, 20) }
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 430)
        .task { await start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func row(_ client: AgentClient) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.title).font(.headline)
                if let note = notes[client] {
                    Text(note.text)
                        .font(.callout)
                        .foregroundStyle(note.isError ? Color(nsColor: Theme.danger) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(subtitle(client)).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing(client)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func trailing(_ client: AgentClient) -> some View {
        if working == client {
            ProgressView().controlSize(.small)
        } else {
            switch statuses[client] ?? .notConnected {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentTheme)
            case .broken:
                Button("Reconnect") { connect(client) }
                    .disabled(!installed.contains(client))
            case .notConnected:
                if installed.contains(client) {
                    Button("Connect") { connect(client) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Not installed").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func subtitle(_ client: AgentClient) -> String {
        if case .broken = statuses[client] { return "Its Trackaro server moved. Reconnect to fix it." }
        switch client {
        case .claudeCode: return "Adds Trackaro to all your projects."
        case .claudeDesktop: return "Adds Trackaro to its settings file."
        case .cursor, .vsCode: return "Opens \(client.title) to confirm the install."
        }
    }

    private func start() async {
        do {
            connector = try AgentConnector(serverPath: AgentConnector.serverPath(appBundle: Bundle.main.bundleURL))
            await refresh()
        } catch {
            setupError = String(describing: error)
        }
    }

    private func refresh() async {
        guard let connector else { return }
        statuses = Dictionary(uniqueKeysWithValues: AgentClient.allCases.map { ($0, connector.status(of: $0)) })
        for client in AgentClient.allCases where isInstalled(client) { installed.insert(client) }
        if await connector.claudeCodeIsInstalled() { installed.insert(.claudeCode) }
        // A connection the user confirmed in the other app replaces the prompt to go and confirm it.
        for client in AgentClient.allCases where statuses[client] == .connected { notes[client] = nil }
    }

    private func isInstalled(_ client: AgentClient) -> Bool {
        if let scheme = client.urlScheme, let url = URL(string: "\(scheme)://") {
            return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        }
        return client == .claudeDesktop && NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeDesktopBundleId) != nil
    }

    private func connect(_ client: AgentClient) {
        guard let connector else { return }
        working = client
        Task {
            defer { working = nil }
            do {
                let note: String
                switch client {
                case .claudeCode:
                    try await connector.connectClaudeCode()
                    note = "Connected. Restart any running sessions to load Trackaro."
                case .claudeDesktop:
                    try connector.connectClaudeDesktop()
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeDesktopBundleId) {
                        NSWorkspace.shared.open(app)
                    }
                    note = "Added. Quit Claude Desktop completely and reopen it to load Trackaro."
                case .cursor, .vsCode:
                    guard let link = connector.installLink(for: client), NSWorkspace.shared.open(link) else {
                        notes[client] = Note(text: "Could not open \(client.title).", isError: true)
                        return
                    }
                    note = "Confirm the install in \(client.title)."
                }
                await refresh()
                notes[client] = Note(text: note)
            } catch {
                notes[client] = Note(text: String(describing: error), isError: true)
            }
        }
    }
}
