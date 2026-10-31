import SwiftUI
import TrackaroCore
import TrackaroKit

/// The new-issue sheet. ⌘↵ creates; with "Create more" on, the sheet stays open and clears for the next one.
struct QuickCreateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var teamId = ""
    @State private var title = ""
    @State private var description = ""
    @State private var stateId: String?
    @State private var priority = Priority.none
    @State private var assigneeId: String?
    @State private var labelIds: Set<String> = []
    @State private var projectId: String?
    @State private var cycleId: String?
    @State private var createMore = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        let snapshot = model.snapshot
        let teams = snapshot?.teams.filter { $0.archivedAt == nil } ?? []
        let states = snapshot?.states(ofTeam: teamId) ?? []
        let labels = snapshot?.labels.filter { $0.teamId == nil || $0.teamId == teamId } ?? []

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if teams.count > 1 {
                    Picker("Team", selection: $teamId) {
                        ForEach(teams) { team in Text(team.key).tag(team.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else if let team = teams.first {
                    Text(team.key).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
                Text("New issue").font(.headline)
            }
            TextField("Issue title", text: $title)
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium))
                .focused($titleFocused)
            TextEditor(text: $description)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: 110)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Add a description in Markdown").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Menu {
                    Button("Default (Backlog)") { stateId = nil }
                    ForEach(states) { state in Button(state.name) { stateId = state.id } }
                } label: {
                    Label(stateId.flatMap { snapshot?.statesById[$0]?.name } ?? "Backlog", systemImage: "circle.dashed")
                }
                Menu {
                    ForEach([Priority.urgent, .high, .medium, .low, .none], id: \.self) { value in
                        Button(value == .none ? "No priority" : value.name.capitalized) { priority = value }
                    }
                } label: {
                    Label(priority == .none ? "Priority" : priority.name.capitalized, systemImage: Symbols.priority(priority).name)
                }
                Menu {
                    Button("No assignee") { assigneeId = nil }
                    ForEach(snapshot?.members.filter { $0.kind != .system } ?? []) { member in
                        Button(member.name) { assigneeId = member.id }
                    }
                } label: {
                    Label(assigneeId.flatMap { snapshot?.membersById[$0]?.name } ?? "Assignee", systemImage: "person.crop.circle")
                }
                Menu {
                    Button("No project") { projectId = nil }
                    ForEach(snapshot?.projects.filter { $0.archivedAt == nil && $0.status.isActive } ?? []) { project in
                        Button(project.name) { projectId = project.id }
                    }
                } label: {
                    Label(projectId.flatMap { snapshot?.projectsById[$0]?.name } ?? "Project", systemImage: "cube")
                }
                if let cycle = cycleId.flatMap({ snapshot?.cyclesById[$0] }), cycle.teamId == teamId {
                    Label(CycleTiming.title(cycle), systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Menu {
                    if labels.isEmpty { Text("No labels yet") }
                    ForEach(labels) { label in
                        Toggle(label.name, isOn: Binding(
                            get: { labelIds.contains(label.id) },
                            set: { on in if on { labelIds.insert(label.id) } else { labelIds.remove(label.id) } }
                        ))
                    }
                } label: {
                    Label(labelIds.isEmpty ? "Labels" : "\(labelIds.count) labels", systemImage: "tag")
                }
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            Divider()
            HStack {
                Toggle("Create more", isOn: $createMore).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create issue") { create() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || teamId.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            let preset = model.quickCreateStateId.flatMap { model.snapshot?.statesById[$0] }
            model.quickCreateStateId = nil
            teamId = preset?.teamId ?? model.defaultTeamId ?? ""
            stateId = preset?.id
            assigneeId = model.defaultAssigneeId
            projectId = model.defaultProjectId
            cycleId = model.defaultCycleId
            titleFocused = true
        }
        .onChange(of: teamId) { oldValue, _ in
            guard !oldValue.isEmpty else { return }
            stateId = nil
            labelIds = labelIds.filter { id in labels.contains { $0.id == id } }
        }
    }

    private func create() {
        let input = NewIssue(
            teamId: teamId, title: title, description: description, stateId: stateId,
            priority: priority, assigneeId: assigneeId, projectId: projectId,
            cycleId: cycleId.flatMap { model.snapshot?.cyclesById[$0] }.flatMap { $0.teamId == teamId ? $0.id : nil },
            labelIds: Array(labelIds)
        )
        guard model.createIssue(input) != nil else { return }
        if createMore {
            title = ""
            description = ""
            titleFocused = true
        } else {
            dismiss()
        }
    }
}
