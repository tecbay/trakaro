import SwiftUI
import TrackaroCore
import TrackaroKit

/// The details panel for the issue under the cursor.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let detail = model.detail {
            IssueInspector(detail: detail)
                .id(detail.issue.id)
        } else {
            ContentUnavailableView {
                Label(model.selection.count > 1 ? "\(model.selection.count) issues selected" : "No issue selected", systemImage: "sidebar.right")
            } description: {
                Text(model.selection.count > 1 ? "Press S, P, A or L to change them all." : "Select an issue to see its details.")
            }
        }
    }
}

/// The same details as the side panel, in a window of their own over the list.
struct IssueModalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let detail = model.detail {
                IssueInspector(detail: detail)
                    .id(detail.issue.id)
            } else {
                ContentUnavailableView("Issue not found", systemImage: "questionmark.circle")
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
    }
}

private struct IssueInspector: View {
    @Environment(AppModel.self) private var model
    let detail: IssueDetail

    @State private var title = ""
    @State private var comment = ""
    @FocusState private var focus: Field?

    enum Field { case title, comment }

    private var issue: Issue { detail.issue }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                titleEditor
                properties
                DescriptionSection(issue: issue)
                links
                if !detail.runs.isEmpty { runs }
                Divider()
                feed
                composer
            }
            .padding(18)
        }
        .onAppear {
            title = issue.title
        }
        .onChange(of: issue.title) { _, newValue in if focus != .title { title = newValue } }
        .onChange(of: focus) { oldValue, _ in
            if oldValue == .title { model.setTitle(title, of: issue.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(issue.identifier)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if detail.isBlocked {
                Label("Blocked", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(nsColor: Theme.danger))
            }
            Spacer()
            Button {
                model.perform(.copyIdentifier)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy identifier")
        }
    }

    private var runs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Automation runs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(detail.runs) { run in
                HStack(spacing: 8) {
                    if run.status == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: Self.symbol(run.status)).foregroundStyle(Self.tint(run.status))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.name).font(.callout)
                        Text("\(run.status.rawValue.capitalized) · \(RelativeTime.string(run.finishedAt ?? run.startedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if run.status == .running {
                        Button("Stop") { model.stopRun(run.id) }.controlSize(.small)
                    }
                    Button("Log") { model.openLog(run.logPath) }.controlSize(.small)
                }
            }
        }
    }

    private static func symbol(_ status: AutomationRunStatus) -> String {
        switch status {
        case .running: "bolt.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle"
        case .interrupted: "exclamationmark.circle"
        }
    }

    private static func tint(_ status: AutomationRunStatus) -> Color {
        switch status {
        case .running: .agent
        case .succeeded: .green
        case .failed: Color(nsColor: Theme.danger)
        case .stopped, .interrupted: .secondary
        }
    }

    private var titleEditor: some View {
        TextField("Title", text: $title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.title3.weight(.semibold))
            .focused($focus, equals: .title)
            .onSubmit { focus = nil }
    }

    private var properties: some View {
        let snapshot = model.snapshot
        let states = snapshot?.states(ofTeam: issue.teamId) ?? []
        let labels = snapshot?.labels.filter { $0.teamId == nil || $0.teamId == issue.teamId } ?? []
        let applied = Set(detail.labels.map(\.id))
        let cycles = snapshot?.cycles.filter { $0.teamId == issue.teamId && $0.completedAt == nil } ?? []
        let ids = [issue.id]

        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            PropertyRow("Status") {
                Menu {
                    ForEach(states) { state in
                        Button(state.name) { model.setState(state, on: ids) }
                    }
                } label: {
                    Label(detail.state?.name ?? "Unknown", systemImage: Symbols.state(detail.state?.category ?? .backlog))
                        .foregroundStyle(Color(nsColor: Theme.stateColor(detail.state?.color ?? "")))
                }
            }
            PropertyRow("Priority") {
                Menu {
                    ForEach([Priority.urgent, .high, .medium, .low, .none], id: \.self) { priority in
                        Button(priority == .none ? "No priority" : priority.name.capitalized) { model.setPriority(priority, on: ids) }
                    }
                } label: {
                    Label(issue.priority == .none ? "No priority" : issue.priority.name.capitalized, systemImage: Symbols.priority(issue.priority).name)
                }
            }
            PropertyRow("Assignee") {
                Menu {
                    Button("No assignee") { model.setAssignee(nil, on: ids) }
                    ForEach(snapshot?.members.filter { $0.kind != .system } ?? []) { member in
                        Button(member.name) { model.setAssignee(member.id, on: ids) }
                    }
                } label: {
                    let member = issue.assigneeId.flatMap { snapshot?.membersById[$0] }
                    Label(member?.name ?? "Unassigned", systemImage: member?.kind == .agent ? "sparkles" : "person.crop.circle")
                }
            }
            PropertyRow("Labels") {
                Menu {
                    if labels.isEmpty { Text("No labels yet") }
                    ForEach(labels) { label in
                        Toggle(label.name, isOn: Binding(get: { applied.contains(label.id) }, set: { _ in model.toggleLabel(label.id, on: ids) }))
                    }
                } label: {
                    Text(detail.labels.isEmpty ? "None" : detail.labels.map(\.name).joined(separator: ", "))
                }
            }
            PropertyRow("Estimate") {
                Menu {
                    Button("No estimate") { model.setEstimate(nil, on: ids) }
                    ForEach([0, 1, 2, 3, 5, 8, 13], id: \.self) { points in
                        Button("\(points) points") { model.setEstimate(points, on: ids) }
                    }
                } label: {
                    Text(issue.estimate.map { "\($0) points" } ?? "None")
                }
            }
            PropertyRow("Project") {
                Menu {
                    Button("No project") { model.setProject(nil, on: ids) }
                    ForEach(snapshot?.projects.filter { $0.archivedAt == nil } ?? []) { project in
                        Button(project.name) { model.setProject(project.id, on: ids) }
                    }
                } label: {
                    Text(issue.projectId.flatMap { snapshot?.projectsById[$0]?.name } ?? "None")
                }
            }
            if let projectId = issue.projectId {
                let milestones = snapshot?.milestones.filter { $0.projectId == projectId } ?? []
                if !milestones.isEmpty {
                    PropertyRow("Milestone") {
                        Menu {
                            Button("No milestone") { model.setMilestone(nil, on: ids) }
                            ForEach(milestones) { milestone in
                                Button(milestone.name) { model.setMilestone(milestone.id, on: ids) }
                            }
                        } label: {
                            Text(issue.milestoneId.flatMap { snapshot?.milestonesById[$0]?.name } ?? "None")
                        }
                    }
                }
            }
            PropertyRow("Cycle") {
                Menu {
                    Button("No cycle") { model.setCycle(nil, on: ids) }
                    ForEach(cycles) { cycle in
                        Button(cycle.name.map { "Cycle \(cycle.number): \($0)" } ?? "Cycle \(cycle.number)") { model.setCycle(cycle.id, on: ids) }
                    }
                } label: {
                    Text(issue.cycleId.flatMap { snapshot?.cyclesById[$0] }.map { "Cycle \($0.number)" } ?? "None")
                }
            }
            PropertyRow("Due") {
                DueDateControl(date: issue.dueDate) { model.setDueDate($0, on: ids) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var links: some View {
        let all = [detail.parent].compactMap { $0 } + detail.children + detail.relations
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(all) { link in
                    Button {
                        model.focus(link.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(link.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                            Text(link.identifier).font(.system(.callout, design: .monospaced))
                            Text(link.title).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
        }
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(detail.feed) { entry in
                FeedRow(entry: entry)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Leave a comment", text: $comment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...8)
                .focused($focus, equals: .comment)
            Button("Send") {
                let body = comment
                comment = ""
                model.addComment(body, to: issue.id)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct PropertyRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

private struct DueDateControl: View {
    let date: CalendarDate?
    let onChange: (CalendarDate?) -> Void
    @State private var picking = false
    @State private var draft = Date()

    var body: some View {
        HStack(spacing: 6) {
            Button(date?.description ?? "None") {
                draft = date.flatMap(Self.date(from:)) ?? Date()
                picking = true
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $picking) {
                VStack {
                    DatePicker("Due", selection: $draft, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    HStack {
                        Button("Clear") { onChange(nil); picking = false }
                        Spacer()
                        Button("Set") { onChange(Self.calendarDate(from: draft)); picking = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
            }
        }
    }

    static func date(from value: CalendarDate) -> Date? {
        Calendar.current.date(from: DateComponents(year: value.year, month: value.month, day: value.day))
    }

    static func calendarDate(from date: Date) -> CalendarDate? {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return CalendarDate(year: year, month: month, day: day)
    }
}

private struct FeedRow: View {
    let entry: IssueDetail.FeedEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.isAgent ? "sparkles" : "person.crop.circle.fill")
                .foregroundStyle(entry.isAgent ? Color.agent : Color.secondary)
                .frame(width: 16)
            switch entry.kind {
            case let .event(text):
                (Text(entry.actor).fontWeight(.medium) + Text(" \(text)") + Text(" · \(RelativeTime.string(entry.at))").foregroundStyle(.tertiary))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case let .comment(body):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.actor).fontWeight(.semibold)
                        if entry.isAgent {
                            Text("Agent").font(.caption2.weight(.semibold)).foregroundStyle(Color.agent)
                        }
                        Text(RelativeTime.string(entry.at)).foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                    MarkdownView(source: body, keepingLineBreaks: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }
}
