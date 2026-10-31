import AppKit
import SwiftUI
import TrackaroCore
import TrackaroKit

/// The column automations editor: rules on the left, the selected rule's form on the right.
struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selectedId: String?
    @State private var draft = Draft()

    /// The form's contents. `id` is nil for a rule not saved yet.
    struct Draft: Equatable {
        var id: String?
        var name = "Ready for agent"
        var stateId = ""
        var directory = ""
        var prompt = Automation.defaultPrompt
        var command = Automation.claudeCommand
        var enabled = true

        init() {}

        init(_ automation: Automation) {
            id = automation.id
            name = automation.name
            stateId = automation.stateId
            directory = automation.directory
            prompt = automation.prompt
            command = automation.command
            enabled = automation.enabled
        }

        var input: AutomationInput {
            AutomationInput(name: name, stateId: stateId, directory: directory, prompt: prompt, command: command, enabled: enabled)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ruleList
                Divider()
                editor
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 560)
        .onAppear(perform: start)
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { selectedId }, set: { select($0) })) {
                ForEach(model.automations) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(rule.name, systemImage: rule.enabled ? "bolt.fill" : "bolt.slash")
                        Text(columnName(rule.stateId)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(rule.id as String?)
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button {
                    newDraft(stateId: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .help("New automation")
                Button {
                    if let id = draft.id { model.deleteAutomation(id) }
                    newDraft(stateId: nil)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(draft.id == nil)
                .help("Delete this automation")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 220)
    }

    private var editor: some View {
        Form {
            TextField("Name", text: $draft.name)
            Picker("When an issue enters", selection: $draft.stateId) {
                ForEach(model.snapshot?.teams.filter { $0.archivedAt == nil } ?? []) { team in
                    Section(team.name) {
                        ForEach(model.snapshot?.states(ofTeam: team.id) ?? []) { state in
                            Text("\(team.key) · \(state.name)").tag(state.id)
                        }
                    }
                }
            }
            LabeledContent("Run in folder") {
                HStack {
                    Text(draft.directory.isEmpty ? "Not chosen" : (draft.directory as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(draft.directory.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
            }
            Section {
                TextEditor(text: $draft.prompt)
                    .font(.body)
                    .frame(height: 130)
            } header: {
                Text("Prompt")
            } footer: {
                Text("Filled in: " + AutomationPrompt.placeholders.map { "{\($0)}" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Command", text: $draft.command, axis: .vertical)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2...4)
                HStack {
                    Button("Use Claude Code default") { draft.command = Automation.claudeCommand }
                    Spacer()
                }
            } header: {
                Text("Command")
            } footer: {
                Text("Runs with your login shell in the folder. The prompt is in $TRACKARO_PROMPT, the issue in $TRACKARO_ISSUE. Only you move cards that trigger this; agents' moves never do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Enabled", isOn: $draft.enabled)
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Text("Issues created in or moved into the column by you start a run. Runs show in the issue's details panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(draft.id == nil ? "Create" : "Save") { save() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(draft.stateId.isEmpty || draft.directory.isEmpty || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
    }

    private func start() {
        let preset = model.automationPreset
        model.automationPreset = nil
        if let preset, let existing = model.automations.first(where: { $0.stateId == preset }) {
            select(existing.id)
        } else if preset != nil || model.automations.isEmpty {
            newDraft(stateId: preset)
        } else {
            select(model.automations.first?.id)
        }
    }

    private func select(_ id: String?) {
        selectedId = id
        if let id, let rule = model.automations.first(where: { $0.id == id }) { draft = Draft(rule) }
    }

    private func newDraft(stateId: String?) {
        selectedId = nil
        var fresh = Draft()
        fresh.stateId = stateId ?? model.snapshot?.states.first { $0.category == .unstarted }?.id ?? ""
        if let state = model.snapshot?.statesById[fresh.stateId], state.category != .unstarted {
            fresh.name = "On \(state.name)"
        }
        draft = fresh
    }

    private func save() {
        guard let saved = model.saveAutomation(id: draft.id, draft.input) else { return }
        select(saved.id)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder the command runs in, usually a repository."
        if panel.runModal() == .OK, let url = panel.url { draft.directory = url.path }
    }

    private func columnName(_ stateId: String) -> String {
        guard let state = model.snapshot?.statesById[stateId] else { return "Missing column" }
        let team = model.snapshot?.teamsById[state.teamId]?.key ?? ""
        return "\(team) · \(state.name)"
    }
}
