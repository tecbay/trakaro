import Charts
import SwiftUI
import TrackaroCore
import TrackaroKit

/// A thin completion bar. Completed share in the accent colour, started share lighter.
struct ProgressBar: View {
    let progress: IssueProgress
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let scope = max(progress.issueCount - progress.canceledCount, 1)
            let done = CGFloat(progress.completedCount) / CGFloat(scope)
            let started = CGFloat(progress.startedCount) / CGFloat(scope)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Color.accentTheme.opacity(0.35)).frame(width: proxy.size.width * min(done + started, 1))
                Capsule().fill(Color.accentTheme).frame(width: proxy.size.width * done)
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(progress.completedCount) of \(progress.issueCount - progress.canceledCount) done")
    }
}

private func percent(_ progress: IssueProgress) -> String {
    "\(Int((progress.fraction * 100).rounded()))%"
}

private func healthColor(_ health: ProjectHealth) -> Color {
    switch health {
    case .onTrack: .green
    case .atRisk: Color(nsColor: Theme.high)
    case .offTrack: Color(nsColor: Theme.danger)
    case .noUpdate: .secondary
    }
}

// MARK: - Projects overview

struct ProjectsOverview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let projects = model.snapshot?.projects.filter { $0.archivedAt == nil } ?? []
        let active = projects.filter(\.status.isActive)
        let closed = projects.filter { !$0.status.isActive }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Group issues from any team toward one outcome. Agents can create and update projects too.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.perform(.newProject)
                    } label: {
                        Label("New project", systemImage: "plus")
                    }
                }
                if projects.isEmpty {
                    ContentUnavailableView("No projects yet", systemImage: "cube.box", description: Text("Create one to track a launch, a migration or any larger piece of work."))
                }
                if !active.isEmpty { section("Active", active) }
                if !closed.isEmpty { section("Completed and canceled", closed) }
            }
            .padding(20)
        }
    }

    private func section(_ title: String, _ projects: [Project]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(projects) { project in
                ProjectCard(project: project, progress: model.progressById[project.id] ?? IssueProgress())
                    .contentShape(Rectangle())
                    .onTapGesture { model.sidebarSelection = .project(project.id) }
            }
        }
    }
}

private struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let progress: IssueProgress

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "cube").font(.title3).foregroundStyle(Color.accentTheme).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.body.weight(.semibold))
                Text(project.summary.isEmpty ? project.status.displayName : project.summary)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 20)
            if project.health != .noUpdate {
                Label(project.health.displayName, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(healthColor(project.health))
            }
            if let target = project.targetDate {
                Label(target.description, systemImage: "flag").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text(progress.issueCount == 0 ? "No issues" : "\(percent(progress)) · \(progress.completedCount)/\(progress.issueCount - progress.canceledCount)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ProgressBar(progress: progress).frame(width: 140)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }
}

// MARK: - Cycles overview

struct CyclesOverview: View {
    @Environment(AppModel.self) private var model
    let teamId: String

    var body: some View {
        let now = model.store?.now() ?? Date()
        let cycles = (model.snapshot?.cycles.filter { $0.teamId == teamId } ?? []).sorted { $0.number > $1.number }
        let current = cycles.filter { [.current, .overdue].contains(CycleTiming.phase($0, now: now)) }
        let upcoming = cycles.filter { CycleTiming.phase($0, now: now) == .upcoming }.reversed()
        let completed = cycles.filter { CycleTiming.phase($0, now: now) == .completed }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Time-boxed iterations. New cycles last a week and start when the last one ends.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.perform(.newCycle)
                    } label: {
                        Label("New cycle", systemImage: "plus")
                    }
                }
                if cycles.isEmpty {
                    ContentUnavailableView("No cycles yet", systemImage: "arrow.triangle.2.circlepath", description: Text("Create a cycle, then set Cycle on the issues you plan to finish in it."))
                }
                if !current.isEmpty { section("Current", current, now: now) }
                if !upcoming.isEmpty { section("Upcoming", Array(upcoming), now: now) }
                if !completed.isEmpty { section("Completed", completed, now: now) }
            }
            .padding(20)
        }
    }

    private func section(_ title: String, _ cycles: [Cycle], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(cycles) { cycle in
                let progress = model.progressById[cycle.id] ?? IssueProgress()
                HStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle").font(.title3).foregroundStyle(Color.accentTheme).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(CycleTiming.title(cycle)).font(.body.weight(.semibold))
                        Text("\(CycleTiming.range(cycle)) · \(CycleTiming.status(cycle, now: now))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(progress.issueCount == 0 ? "No issues" : "\(percent(progress)) · \(progress.completedCount)/\(progress.issueCount - progress.canceledCount)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        ProgressBar(progress: progress).frame(width: 140)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                .contentShape(Rectangle())
                .onTapGesture { model.sidebarSelection = .cycle(cycle.id) }
            }
        }
    }
}

// MARK: - Project header

struct ProjectHeader: View {
    @Environment(AppModel.self) private var model
    let progress: ProjectProgress
    @State private var addingMilestone = false
    @State private var milestoneName = ""

    private var project: Project { progress.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Menu {
                    ForEach(ProjectStatus.allCases, id: \.self) { status in
                        Button(status.displayName) { model.updateProject(project.id, ProjectPatch(status: status)) }
                    }
                } label: {
                    Label(project.status.displayName, systemImage: "circle.dashed")
                }
                Menu {
                    ForEach(ProjectHealth.allCases, id: \.self) { health in
                        Button(health.displayName) { model.updateProject(project.id, ProjectPatch(health: health)) }
                    }
                } label: {
                    Label(project.health.displayName, systemImage: "heart.text.square").foregroundStyle(healthColor(project.health))
                }
                Menu {
                    Button("No lead") { model.updateProject(project.id, ProjectPatch(leadId: .clear)) }
                    ForEach(model.snapshot?.members.filter { $0.kind != .system } ?? []) { member in
                        Button(member.name) { model.updateProject(project.id, ProjectPatch(leadId: .set(member.id))) }
                    }
                } label: {
                    Label(project.leadId.flatMap { model.snapshot?.membersById[$0]?.name } ?? "No lead", systemImage: "person.crop.circle")
                }
                if let target = project.targetDate {
                    Label("Target \(target.description)", systemImage: "flag").foregroundStyle(.secondary)
                }
                Spacer()
                Text(progress.overall.issueCount == 0 ? "No issues yet"
                     : "\(percent(progress.overall)) · \(progress.overall.completedCount) of \(progress.overall.issueCount - progress.overall.canceledCount) done")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .font(.callout)
            ProgressBar(progress: progress.overall, height: 7)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(progress.milestones) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "diamond.fill").font(.caption2).foregroundStyle(Color.accentTheme)
                            Text(item.milestone.name)
                            Text(item.progress.issueCount == 0 ? "0" : "\(item.progress.completedCount)/\(item.progress.issueCount - item.progress.canceledCount)")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                    }
                    Button {
                        model.sidebarSelection = .artifacts(project.id)
                    } label: {
                        Label(model.projectArtifactCount == 1 ? "1 artifact" : "\(model.projectArtifactCount) artifacts", systemImage: "doc.richtext").font(.callout)
                    }
                    .buttonStyle(.borderless)
                    Button {
                        milestoneName = ""
                        addingMilestone = true
                    } label: {
                        Label("Milestone", systemImage: "plus").font(.callout)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .alert("New milestone", isPresented: $addingMilestone) {
            TextField("Name", text: $milestoneName)
            Button("Add") { model.createMilestone(named: milestoneName, in: project.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Set Milestone on an issue in its details panel to count it here.")
        }
    }
}

// MARK: - Cycle header

struct CycleHeader: View {
    @Environment(AppModel.self) private var model
    let progress: CycleProgress

    var body: some View {
        let cycle = progress.cycle
        let now = model.store?.now() ?? Date()
        let summary = progress.issueProgress
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Label(CycleTiming.range(cycle), systemImage: "calendar")
                Text(CycleTiming.status(cycle, now: now))
                    .foregroundStyle(CycleTiming.phase(cycle, now: now) == .overdue ? Color(nsColor: Theme.danger) : .secondary)
                Spacer()
                stat("Scope", progress.issueCount - progress.canceledCount)
                stat("Started", summary.startedCount)
                stat("Done", progress.completedCount)
                if progress.totalEstimate > 0 {
                    stat("Points", progress.completedEstimate, of: progress.totalEstimate)
                }
                if cycle.completedAt == nil {
                    Button("Complete cycle") { model.perform(.completeCycle) }
                        .help("Close this cycle, and choose what happens to unfinished issues")
                }
            }
            .font(.callout)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.issueCount == 0 ? "No issues yet" : "\(percent(summary)) complete")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    ProgressBar(progress: summary, height: 7).frame(width: 220)
                }
                BurnUpChart(points: BurnUp.points(start: cycle.startsAt, end: cycle.endsAt, now: now, completions: model.cycleCompletions),
                            scope: progress.issueCount - progress.canceledCount, cycle: cycle)
                    .frame(height: 70)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func stat(_ title: String, _ value: Int, of total: Int? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(total.map { "\(value)/\($0)" } ?? "\(value)").font(.callout.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct BurnUpChart: View {
    let points: [BurnUpPoint]
    let scope: Int
    let cycle: Cycle

    var body: some View {
        Chart {
            RuleMark(y: .value("Scope", scope))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(points) { point in
                AreaMark(x: .value("Day", point.day), y: .value("Done", point.completed))
                    .foregroundStyle(Color.accentTheme.opacity(0.15))
                LineMark(x: .value("Day", point.day), y: .value("Done", point.completed))
                    .foregroundStyle(Color.accentTheme)
            }
        }
        .chartXScale(domain: cycle.startsAt...cycle.endsAt)
        .chartYScale(domain: 0...max(scope, points.last?.completed ?? 0, 1))
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(values: [0, scope]) }
        .accessibilityLabel("Completed issues per day against a scope of \(scope)")
    }
}

// MARK: - New project

struct NewProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var status = ProjectStatus.planned
    @State private var hasTarget = false
    @State private var target = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New project").font(.headline)
            TextField("Project name", text: $name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium))
                .focused($nameFocused)
            TextField("One-line summary", text: $summary)
                .textFieldStyle(.plain)
            HStack(spacing: 12) {
                Picker("Status", selection: $status) {
                    ForEach(ProjectStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
                Toggle("Target date", isOn: $hasTarget)
                if hasTarget {
                    DatePicker("", selection: $target, displayedComponents: .date).labelsHidden()
                }
            }
            .controlSize(.small)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create project") { create() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { nameFocused = true }
    }

    private func create() {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: target)
        let date = hasTarget ? components.year.flatMap { year in
            components.month.flatMap { month in components.day.flatMap { CalendarDate(year: year, month: month, day: $0) } }
        } : nil
        if model.createProject(name: name, summary: summary, status: status, targetDate: date) { dismiss() }
    }
}
