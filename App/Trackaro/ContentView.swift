import SwiftUI
import TrackaroCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var draftTitle = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider()
            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
            }
            issueList
        }
        .navigationTitle(model.team?.name ?? "Trackaro")
    }

    private var composer: some View {
        HStack {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("New issue", text: $draftTitle)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .onSubmit(submit)
        }
        .padding(10)
        .onAppear { composerFocused = true }
    }

    private var issueList: some View {
        List {
            ForEach(model.states) { state in
                let issues = model.issues(in: state)
                if !issues.isEmpty {
                    Section(state.name) {
                        ForEach(issues) { issue in
                            IssueRow(issue: issue)
                                .contextMenu { moveMenu(for: issue) }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func moveMenu(for issue: Issue) -> some View {
        ForEach(model.states.filter { $0.id != issue.stateId }) { state in
            Button("Move to \(state.name)") { model.move(issue, to: state) }
        }
    }

    private func submit() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        model.createIssue(title: title)
        draftTitle = ""
    }
}

private struct IssueRow: View {
    let issue: Issue

    var body: some View {
        HStack(spacing: 10) {
            Text(issue.identifier)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
            Text(issue.title)
                .lineLimit(1)
            Spacer()
            if issue.priority != .none {
                Text(issue.priority.name.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
