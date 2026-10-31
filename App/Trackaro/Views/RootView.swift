import SwiftUI
import TrackaroCore
import TrackaroKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            IssueListPane()
                .inspector(isPresented: Binding(
                    // The artifacts page has its own viewer in that space.
                    get: { model.inspectorPresented && !model.currentItem.isArtifacts },
                    set: { model.inspectorPresented = $0 }
                )) {
                    InspectorView()
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
                }
        }
        .overlay {
            if let overlay = model.overlay {
                OverlayHost(overlay: overlay)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.toast)
        .sheet(isPresented: $model.quickCreatePresented) {
            QuickCreateView()
        }
        .sheet(isPresented: $model.automationsPresented) {
            AutomationsView()
        }
        .sheet(isPresented: $model.connectAgentPresented) {
            ConnectAgentView()
        }
        .sheet(isPresented: $model.backupsPresented) {
            BackupsView()
        }
        .sheet(isPresented: $model.newProjectPresented) {
            NewProjectView()
        }
        .confirmationDialog(
            "Complete \(model.cycleToComplete.map(CycleTiming.title) ?? "cycle")?",
            isPresented: Binding(get: { model.cycleToComplete != nil }, set: { if !$0 { model.cycleToComplete = nil } }),
            presenting: model.cycleToComplete
        ) { cycle in
            Button("Move unfinished issues to the next cycle") { model.completeCycle(cycle, moveUnfinished: true) }
            Button("Leave them in this cycle") { model.completeCycle(cycle, moveUnfinished: false) }
            Button("Cancel", role: .cancel) { model.cycleToComplete = nil }
        } message: { cycle in
            Text("\(model.unfinishedIssueIds(in: cycle.id).count) issues are not finished. Moving them creates the next cycle if there is none yet.")
        }
        .onOpenURL { url in model.open(url) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section {
                Label(SidebarItem.myIssues.title(in: model.snapshot), systemImage: SidebarItem.myIssues.symbol)
                    .tag(SidebarItem.myIssues)
                Label {
                    Text("Agent activity")
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(Color.agent)
                }
                .tag(SidebarItem.agentActivity)
            }
            Section("Projects") {
                Label("All projects", systemImage: SidebarItem.projects.symbol)
                    .tag(SidebarItem.projects)
                Label("Artifacts", systemImage: SidebarItem.artifacts(nil).symbol)
                    .tag(SidebarItem.artifacts(nil))
                ForEach(model.snapshot?.projects.filter { $0.archivedAt == nil && $0.status.isActive } ?? []) { project in
                    Label(project.name, systemImage: "cube")
                        .tag(SidebarItem.project(project.id))
                }
            }
            if let views = model.snapshot?.savedViews, !views.isEmpty {
                Section("Views") {
                    ForEach(views) { view in
                        Label(view.name, systemImage: SidebarItem.view(view.id).symbol)
                            .tag(SidebarItem.view(view.id))
                            .contextMenu {
                                Button("Delete view", role: .destructive) { model.deleteView(view.id) }
                            }
                    }
                }
            }
            ForEach(model.snapshot?.teams.filter { $0.archivedAt == nil } ?? []) { team in
                Section(team.name) {
                    ForEach(SidebarItem.TeamPage.allCases, id: \.self) { page in
                        Label(page.title, systemImage: page.symbol)
                            .tag(SidebarItem.team(team.id, page))
                    }
                    if let current = model.currentCycle(teamId: team.id) {
                        Label("Current cycle", systemImage: SidebarItem.cycle(current.id).symbol)
                            .tag(SidebarItem.cycle(current.id))
                    }
                    Label("Cycles", systemImage: SidebarItem.cycles(team.id).symbol)
                        .tag(SidebarItem.cycles(team.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.perform(.connectAgent)
            } label: {
                Label("Connect an agent", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.perform(.newIssue)
                } label: {
                    Label("New issue", systemImage: "square.and.pencil")
                }
                .help("New issue (C)")
            }
        }
    }
}

struct IssueListPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let error = model.loadError {
                ContentUnavailableView("Could not open the database", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.currentItem == .projects {
                ProjectsOverview()
            } else if case let .artifacts(projectId) = model.currentItem {
                ArtifactsPage(projectId: projectId)
            } else if case let .cycles(teamId) = model.currentItem {
                CyclesOverview(teamId: teamId)
            } else if model.layout == .board, !model.columns.isEmpty {
                BoardView()
            } else if model.rows.isEmpty, model.savedView == nil, !model.filter.isEmpty {
                ContentUnavailableView {
                    Label("No matching issues", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Nothing here matches these filters.")
                } actions: {
                    Button("Clear filters") { model.perform(.clearFilters) }
                }
            } else if model.rows.isEmpty {
                ContentUnavailableView {
                    Label(model.currentItem.title(in: model.snapshot), systemImage: model.currentItem.symbol)
                } description: {
                    Text(model.currentItem.emptyMessage)
                }
            } else {
                IssueTableView(
                    rows: model.rows,
                    version: model.rowsVersion,
                    selection: model.selection,
                    cursor: model.cursor,
                    onSelect: { ids, cursor in model.select(ids, cursor: cursor) },
                    onOpen: { id in model.focus(id) },
                    onCommand: { command in model.perform(command) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let progress = model.projectProgress { ProjectHeader(progress: progress) }
                if let progress = model.cycleProgress { CycleHeader(progress: progress) }
                if model.filterBarVisible { FilterBar() }
            }
        }
        .navigationTitle(model.currentItem.title(in: model.snapshot))
        .navigationSubtitle(model.rows.isEmpty ? "" : "\(model.issueCount) issues")
        .toolbar {
            ToolbarItemGroup {
                if !model.currentItem.isOverview { listControls }
                Button {
                    model.perform(.palette)
                } label: {
                    Label("Command palette", systemImage: "command")
                }
                .help("Command palette (⌘K)")
                Button {
                    model.perform(.toggleInspector)
                } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Toggle details (])")
            }
        }
    }

    @ViewBuilder private var listControls: some View {
        Group {
                Picker("Layout", selection: Binding(
                    get: { model.layout },
                    set: { value in if value != model.layout { model.perform(.toggleLayout) } }
                )) {
                    Label("List", systemImage: "list.bullet").tag(ViewLayout.list)
                    Label("Board", systemImage: "rectangle.split.3x1").tag(ViewLayout.board)
                }
                .pickerStyle(.segmented)
                .help("Board or list (⌘B)")
                Button {
                    model.perform(.filter)
                } label: {
                    Label("Filter", systemImage: model.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter (F)")
        }
    }
}

struct ToastView: View {
    let toast: AppModel.Toast

    var body: some View {
        Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(toast.isError ? Color(nsColor: Theme.danger) : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
