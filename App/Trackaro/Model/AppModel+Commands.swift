import Foundation
import TrackaroCore
import TrackaroKit

/// One row in the command palette or a property picker.
struct OverlayItem: Identifiable, Equatable {
    enum Action: Equatable {
        case command(AppCommand)
        case navigate(SidebarItem)
        case openIssue(String)
        case state(String)
        case priority(Priority)
        case assignee(String?)
        case label(String)
        case estimate(Int?)
        case filter(FilterOption)
        case saveView(String)
        case updateView
    }

    enum Tint: Equatable {
        case hex(String)
        case priority(Priority)
        case agent
        case secondary
    }

    let id: String
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Tint = .secondary
    var shortcut: String?
    var checked = false
    let action: Action
}

extension AppModel {
    // MARK: Commands

    func canPerform(_ command: AppCommand) -> Bool {
        switch command {
        case .setStatus, .setPriority, .setAssignee, .setLabels, .setEstimate, .assignToMe, .copyIdentifier, .archive, .toggleSelect, .open:
            !targets.isEmpty
        case .next, .previous, .extendDown, .extendUp:
            issueCount > 0
        case .cardUp, .cardDown, .columnLeft, .columnRight:
            layout == .board && issueCount > 0
        case .moveToPreviousStatus, .moveToNextStatus:
            !targets.isEmpty
        case .undo:
            history.canUndo
        case .redo:
            history.canRedo
        case .clearSelection:
            !selection.isEmpty || cursor != nil || overlay != nil
        case .clearFilters:
            !filter.isEmpty || textFilterVisible
        case .runAutomation:
            !targets.isEmpty && !automations.isEmpty
        case .completeCycle:
            openCycle.map { $0.completedAt == nil } ?? false
        case .revertView:
            isViewModified
        case .deleteView:
            savedView != nil
        case .palette, .shortcuts, .newIssue, .toggleLayout, .toggleSidebar, .toggleInspector,
             .goMyIssues, .goAgentActivity, .goIssues, .goActive, .goBacklog, .filter, .searchInView, .saveView, .automations,
             .goProjects, .goCycles, .newProject, .newCycle:
            true
        }
    }

    func perform(_ command: AppCommand) {
        switch command {
        case .palette: overlay = overlay == .palette ? nil : .palette
        case .shortcuts: overlay = overlay == .shortcuts ? nil : .shortcuts
        case .newIssue: quickCreatePresented = true
        case .toggleLayout: toggleLayout()
        case .toggleSidebar: sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        case .toggleInspector: inspectorPresented.toggle()
        case .undo: undo()
        case .redo: redo()
        case .goMyIssues: sidebarSelection = .myIssues
        case .goAgentActivity: sidebarSelection = .agentActivity
        case .goIssues: goToTeam(.all)
        case .goActive: goToTeam(.active)
        case .goBacklog: goToTeam(.backlog)
        case .goProjects: sidebarSelection = .projects
        case .goCycles: goToCurrentCycle()
        case .newProject: newProjectPresented = true
        case .newCycle: createCycle()
        case .completeCycle: if let cycle = openCycle { requestCompleteCycle(cycle) }
        case .automations: openAutomations()
        case .runAutomation: runAutomationNow()
        case .filter: overlay == .filter ? (overlay = nil) : openFilterPicker()
        case .searchInView: focusFilterText()
        case .clearFilters: clearFilters()
        case .saveView: overlay = .saveView
        case .revertView: revertView()
        case .deleteView: if let id = savedView?.id { deleteView(id) }
        case .next: layout == .board ? moveCardCursor(by: 1) : moveCursor(by: 1)
        case .previous: layout == .board ? moveCardCursor(by: -1) : moveCursor(by: -1)
        case .cardUp: moveCardCursor(by: -1)
        case .cardDown: moveCardCursor(by: 1)
        case .columnLeft: moveColumnCursor(by: -1)
        case .columnRight: moveColumnCursor(by: 1)
        case .moveToPreviousStatus: stepStatus(by: -1)
        case .moveToNextStatus: stepStatus(by: 1)
        case .extendDown: moveCursor(by: 1, extend: true)
        case .extendUp: moveCursor(by: -1, extend: true)
        case .toggleSelect: toggleSelection()
        case .open: inspectorPresented = true
        case .clearSelection: clearSelection()
        case .setStatus: openPicker(.status)
        case .setPriority: openPicker(.priority)
        case .setAssignee: openPicker(.assignee)
        case .setLabels: openPicker(.labels)
        case .setEstimate: openPicker(.estimate)
        case .assignToMe: assignToMe()
        case .copyIdentifier: copyIdentifiers()
        case .archive: archiveTargets()
        }
    }

    private func goToTeam(_ page: SidebarItem.TeamPage) {
        guard let teamId = defaultTeamId else { return }
        sidebarSelection = .team(teamId, page)
    }

    // MARK: Overlay

    func openPicker(_ kind: PickerKind) {
        guard !targets.isEmpty else { return }
        pickerTargets = targets
        overlay = .picker(kind)
    }

    var overlayPlaceholder: String {
        switch overlay {
        case .palette: "Type a command, or search issues"
        case .picker(.status): "Change status…"
        case .picker(.priority): "Set priority…"
        case .picker(.assignee): "Assign to…"
        case .picker(.labels): "Toggle labels…"
        case .picker(.estimate): "Set estimate…"
        case .filter: "Filter by status, priority, assignee, label…"
        case .saveView: isViewModified ? "Name a new view, or press Return to update this one" : "Name the new view"
        case .shortcuts, nil: ""
        }
    }

    func moveOverlaySelection(by offset: Int) {
        guard !overlayItems.isEmpty else { return }
        overlayIndex = (overlayIndex + offset + overlayItems.count) % overlayItems.count
    }

    func confirmOverlay(at index: Int? = nil) {
        let position = index ?? overlayIndex
        guard overlayItems.indices.contains(position) else { return }
        run(overlayItems[position].action)
    }

    private func run(_ action: OverlayItem.Action) {
        let ids = pickerTargets
        switch action {
        case let .command(command):
            overlay = nil
            perform(command)
        case let .navigate(item):
            overlay = nil
            sidebarSelection = item
        case let .openIssue(id):
            overlay = nil
            focus(id)
        case let .state(id):
            overlay = nil
            if let state = snapshot?.statesById[id] { setState(state, on: ids) }
        case let .priority(priority):
            overlay = nil
            setPriority(priority, on: ids)
        case let .assignee(memberId):
            overlay = nil
            setAssignee(memberId, on: ids)
        case let .label(id):
            toggleLabel(id, on: ids)
        case let .estimate(points):
            overlay = nil
            setEstimate(points, on: ids)
        case let .filter(option):
            toggleFilter(option)
        case let .saveView(name):
            overlay = nil
            saveView(named: name)
        case .updateView:
            overlay = nil
            updateCurrentView()
        }
    }

    func refreshOverlay() {
        let items: [OverlayItem]
        switch overlay {
        case .palette: items = paletteItems()
        case let .picker(kind): items = FuzzyMatch.rank(pickerItems(kind), query: overlayQuery) { $0.title }
        case .filter: items = FuzzyMatch.rank(filterItems(), query: overlayQuery) { "\($0.subtitle ?? "") \($0.title)" }
        case .saveView: items = saveViewItems()
        case .shortcuts, nil: items = []
        }
        overlayItems = items
        if overlayIndex >= items.count { overlayIndex = max(items.count - 1, 0) }
    }

    private func paletteItems() -> [OverlayItem] {
        var commands = AppCommand.allCases.filter { $0.definition.inPalette && canPerform($0) }.map { command in
            OverlayItem(id: "command.\(command.rawValue)", title: command.definition.title, subtitle: command.definition.section,
                        symbol: "command", shortcut: command.definition.binding?.description, action: .command(command))
        }
        var places: [SidebarItem] = [.projects] + (snapshot?.savedViews.map { .view($0.id) } ?? [])
        places += snapshot?.projects.filter { $0.archivedAt == nil && $0.status.isActive }.map { .project($0.id) } ?? []
        for team in snapshot?.teams.filter({ $0.archivedAt == nil }) ?? [] {
            places += SidebarItem.TeamPage.allCases.map { .team(team.id, $0) }
            places.append(.cycles(team.id))
        }
        commands += places.map { place in
            OverlayItem(id: "go.\(place)", title: "Go to \(place.title(in: snapshot))", subtitle: "Navigation",
                        symbol: place.symbol, action: .navigate(place))
        }
        let query = overlayQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commands }

        let rankedCommands = Array(FuzzyMatch.rank(commands, query: query) { $0.title }.prefix(6))
        var issues: [Issue] = []
        if let store {
            if IssueKey(query) != nil, let exact = try? store.issue(query) { issues.append(exact) }
            for match in (try? store.searchIssues(query, limit: 8)) ?? [] where !issues.contains(where: { $0.id == match.id }) {
                issues.append(match)
            }
        }
        let issueItems = issues.prefix(8).map { issue in
            OverlayItem(
                id: "issue.\(issue.id)", title: issue.title, subtitle: issue.identifier,
                symbol: snapshot?.statesById[issue.stateId].map { Symbols.state($0.category) } ?? "circle",
                tint: .hex(snapshot?.statesById[issue.stateId]?.color ?? "#95A2B3"), action: .openIssue(issue.id)
            )
        }
        return IssueKey(query) != nil ? issueItems + rankedCommands : rankedCommands + issueItems
    }

    private func pickerItems(_ kind: PickerKind) -> [OverlayItem] {
        guard let snapshot, let store, let first = pickerTargets.first, let firstIssue = try? store.issue(first) else { return [] }
        let issues = pickerTargets.compactMap { try? store.issue($0) }
        func shared<Value: Equatable>(_ value: (Issue) -> Value) -> Value? {
            let values = issues.map(value)
            return values.allSatisfy { $0 == values.first } ? values.first : nil
        }

        switch kind {
        case .status:
            let current = shared(\.stateId)
            return snapshot.states(ofTeam: firstIssue.teamId).map { state in
                OverlayItem(id: state.id, title: state.name, symbol: Symbols.state(state.category), tint: .hex(state.color),
                            checked: current == state.id, action: .state(state.id))
            }
        case .priority:
            let current = shared(\.priority)
            return [Priority.urgent, .high, .medium, .low, .none].map { priority in
                OverlayItem(id: "\(priority.rawValue)", title: priority == .none ? "No priority" : priority.name.capitalized,
                            symbol: Symbols.priority(priority).name, tint: .priority(priority),
                            checked: current == priority, action: .priority(priority))
            }
        case .assignee:
            let current = shared(\.assigneeId)
            let people = snapshot.members.filter { $0.kind != .system }.sorted { lhs, _ in lhs.id == user?.id }
            return [OverlayItem(id: "none", title: "No assignee", symbol: "person.crop.circle.badge.xmark",
                                checked: current == .some(nil), action: .assignee(nil))]
                + people.map { member in
                    OverlayItem(id: member.id, title: member.id == user?.id ? "\(member.name) (you)" : member.name,
                                subtitle: member.kind == .agent ? "Agent" : nil,
                                symbol: member.kind == .agent ? "sparkles" : "person.crop.circle",
                                tint: member.kind == .agent ? .agent : .secondary,
                                checked: current == member.id, action: .assignee(member.id))
                }
        case .labels:
            let applied = (try? store.labelIds(forIssues: pickerTargets)) ?? [:]
            let teamIds = Set(issues.map(\.teamId))
            return snapshot.labels.filter { $0.teamId == nil || teamIds.contains($0.teamId ?? "") }.map { label in
                OverlayItem(id: label.id, title: label.name, symbol: "circle.fill", tint: .hex(label.color),
                            checked: pickerTargets.allSatisfy { applied[$0]?.contains(label.id) == true }, action: .label(label.id))
            }
        case .estimate:
            let current = shared(\.estimate)
            return [OverlayItem(id: "none", title: "No estimate", symbol: "minus", checked: current == .some(nil), action: .estimate(nil))]
                + ([0, 1, 2, 3, 5, 8, 13] as [Int]).map { points in
                    OverlayItem(id: "\(points)", title: "\(points) \(points == 1 ? "point" : "points")", symbol: "number",
                                checked: current == points, action: .estimate(points))
                }
        }
    }
}
