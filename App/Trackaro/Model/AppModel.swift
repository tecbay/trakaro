import AppKit
import Foundation
import Observation
import os
import SwiftUI
import TrackaroCore
import TrackaroKit

/// The window's state: what is loaded, what is selected, which overlay is open.
///
/// Agents write through `trackaro-mcp`, a separate process on the same database. The model notices their writes
/// by polling the change log's high-water mark, which is one indexed lookup, and reloads only when it moved.
/// Rows are rebuilt on every reload but the table only redraws when they actually differ.
@MainActor
@Observable
final class AppModel {
    enum Overlay: Equatable {
        case palette
        case picker(PickerKind)
        case filter
        case saveView
        case shortcuts
    }

    enum PickerKind: Equatable {
        case status, priority, assignee, labels, estimate
    }

    // MARK: Data

    private(set) var snapshot: WorkspaceSnapshot?
    private(set) var user: Member?
    private(set) var rows: [ListRow] = []
    private(set) var rowsVersion = 0
    private(set) var columns: [BoardColumn] = []
    /// Board or list, remembered per sidebar item.
    private(set) var layouts: [String: ViewLayout] = AppModel.loadLayouts()
    /// The filter set on each sidebar item, remembered across launches. For a saved view it is the unsaved edit.
    var filters: [String: IssueFilter] = AppModel.loadFilters()
    private(set) var detail: IssueDetail?
    private(set) var automations: [Automation] = []
    /// Progress per project or cycle, for the overview pages.
    private(set) var progressById: [String: IssueProgress] = [:]
    private(set) var projectProgress: ProjectProgress?
    private(set) var cycleProgress: CycleProgress?
    /// When each completed issue of the open cycle page was completed, for its burn-up chart.
    private(set) var cycleCompletions: [Date] = []
    private(set) var loadError: String?

    // MARK: Navigation and selection

    var sidebarSelection: SidebarItem? = .myIssues {
        didSet {
            guard sidebarSelection != oldValue else { return }
            selection = []
            cursor = nil
            textFilterVisible = false
            filterDraft = filter.text ?? ""
            reloadRows()
            loadDetail()
        }
    }

    var currentItem: SidebarItem { sidebarSelection ?? .myIssues }
    var selection: Set<String> = []
    private(set) var cursor: String?
    private var anchor: String?

    // MARK: Chrome

    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var inspectorPresented = true
    var overlay: Overlay? {
        didSet {
            guard overlay != oldValue else { return }
            overlayQuery = ""
            overlayIndex = 0
            refreshOverlay()
        }
    }
    var overlayQuery = "" {
        didSet {
            guard overlayQuery != oldValue else { return }
            overlayIndex = 0
            refreshOverlay()
        }
    }
    var overlayItems: [OverlayItem] = []
    var overlayIndex = 0
    /// The issues an open picker applies to, captured when it opened so the list can change underneath.
    var pickerTargets: [String] = []
    /// Shows the filter bar's text field even with no filter set, after `/`.
    var textFilterVisible = false
    /// The text field's contents, kept apart from the filter so typing a trailing space is not trimmed away.
    var filterDraft = ""
    /// Bumped to move focus into the filter bar's text field.
    var filterFocusRequest = 0
    var automationsPresented = false
    var connectAgentPresented = false
    var newProjectPresented = false
    /// The cycle waiting for the user to choose what happens to its unfinished issues.
    var cycleToComplete: Cycle?
    /// The column the automations editor starts a new rule for, when opened from a board column.
    var automationPreset: String?
    var quickCreatePresented = false
    /// The state a new issue starts in when created from a board column's + button.
    var quickCreateStateId: String?
    private(set) var toast: Toast?

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    // MARK: Internals

    private(set) var store: TrackaroStore?
    var history = EditHistory()
    private var seenChangeSeq: Int64 = 0
    private var watcher: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    var automationRunner: AutomationRunner?
    private var rowIds: [String] = []

    static let log = Logger(subsystem: "app.trackaro.Trackaro", category: "sync")
    /// How long an agent's change stays flagged on its row or card.
    static let recentAgentWindow: TimeInterval = 15 * 60
    private static let layoutsKey = "layouts"
    static let pollInterval: Duration = .milliseconds(300)

    /// The database file: `TRACKARO_DATABASE` when set, which keeps development runs off real data.
    static func databaseURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["TRACKARO_DATABASE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return try TrackaroStore.defaultURL()
    }

    // MARK: Lifecycle

    func start() {
        guard store == nil else { return }
        do {
            let store = try TrackaroStore.open(at: Self.databaseURL())
            let user = try store.localUser()
            if try store.teams().isEmpty {
                try store.createTeam(key: "TASK", name: "Tasks", by: user.id)
            }
            self.store = store
            self.user = user
            reloadAll()
            startAutomations(store: store)
            watchForExternalChanges()
        } catch {
            loadError = String(describing: error)
        }
    }

    /// Re-reads everything the window shows. Cheap: reference tables are small and the list is one query.
    func reloadAll() {
        guard let store else { return }
        do {
            seenChangeSeq = try store.latestChangeSeq()
            snapshot = try store.snapshot()
            automations = try store.automations()
        } catch {
            showError(error)
        }
        switch currentItem {
        case let .team(id, _) where snapshot?.teamsById[id] == nil, let .view(id) where snapshot?.savedViewsById[id] == nil,
             let .project(id) where snapshot?.projectsById[id] == nil, let .cycle(id) where snapshot?.cyclesById[id] == nil,
             let .cycles(id) where snapshot?.teamsById[id] == nil:
            sidebarSelection = .myIssues
        default:
            break
        }
        reloadRows()
        loadDetail()
        if overlay != nil { refreshOverlay() }
    }

    func reloadRows() {
        guard let store, let snapshot else { return }
        do {
            let issues: [Issue]
            var notes: [String: String] = [:]
            var grouping = ListGrouping.state
            let filter = self.filter
            let page = pageQuery(for: currentItem)
            projectProgress = nil
            cycleProgress = nil
            cycleCompletions = []
            switch currentItem {
            case .myIssues:
                issues = try store.queryIssues(filter.applied(to: page)).issues
                grouping = .category
            case .agentActivity:
                var changes = try store.recentChanges(by: .agent)
                if !filter.isEmpty {
                    let scoped = IssueQuery(issueIds: changes.map(\.issue.id), limit: TrackaroStore.maxPageSize)
                    let kept = Set(try store.queryIssues(filter.applied(to: scoped)).issues.map(\.id))
                    changes = changes.filter { kept.contains($0.issue.id) }
                }
                issues = changes.map(\.issue)
                for change in changes { notes[change.issue.id] = "\(change.member.name) · \(RelativeTime.string(change.at))" }
                grouping = .none
            case .team:
                issues = try store.queryIssues(filter.applied(to: page)).issues
            case .view:
                issues = try store.queryIssues(filter.applied(to: page)).issues
                grouping = boardTeamId == nil ? .category : .state
            case .projects:
                issues = []
                progressById = try store.projectsProgress()
            case let .cycles(teamId):
                issues = []
                progressById = try store.cyclesProgress(teamId: teamId)
            case let .project(id):
                issues = try store.queryIssues(filter.applied(to: page)).issues
                grouping = .category
                projectProgress = try store.projectProgress(projectId: id)
            case let .cycle(id):
                issues = try store.queryIssues(filter.applied(to: page)).issues
                let progress = try store.cycleProgress(cycleId: id)
                cycleProgress = progress
                cycleCompletions = try store.queryIssues(IssueQuery(stateCategories: [.completed], cycle: .anyOf([id]), limit: TrackaroStore.maxPageSize))
                    .issues.compactMap(\.completedAt)
            }
            if notes.isEmpty {
                let recent = Date().addingTimeInterval(-Self.recentAgentWindow)
                for change in try store.recentChanges(by: .agent, limit: 100) where change.at >= recent {
                    notes[change.issue.id] = "\(change.member.name) · \(RelativeTime.string(change.at))"
                }
            }
            let labelIds = try store.labelIds(forIssues: issues.map(\.id))
            let parents = try store.identifiers(forIssueIds: issues.compactMap(\.parentId))
            let rowNotes = currentItem == .agentActivity ? notes : [:]
            let nextRows = IssueRowBuilder.rows(issues, snapshot: snapshot, labelIds: labelIds, parentIdentifiers: parents, grouping: grouping, notes: rowNotes)
            let nextColumns = boardColumns(for: issues, snapshot: snapshot, labelIds: labelIds, parents: parents, notes: notes)
            let nextIds = layout == .board ? nextColumns.flatMap { $0.cards.map(\.id) } : nextRows.compactMap(\.issueId)
            if nextRows != rows || nextColumns != columns || nextIds != rowIds {
                rows = nextRows
                columns = nextColumns
                rowIds = nextIds
                rowsVersion += 1
            }
            let visible = Set(rowIds)
            selection = selection.intersection(visible)
            if let cursor, !visible.contains(cursor) { self.cursor = nil }
        } catch {
            showError(error)
        }
    }

    private func boardColumns(
        for issues: [Issue], snapshot: WorkspaceSnapshot, labelIds: [String: [String]], parents: [String: String], notes: [String: String]
    ) -> [BoardColumn] {
        guard layout == .board else { return [] }
        let items = issues.map {
            IssueRowBuilder.item($0, snapshot: snapshot, labelIds: labelIds[$0.id] ?? [],
                                 parentIdentifier: $0.parentId.flatMap { parents[$0] }, note: notes[$0.id])
        }
        if let teamId = boardTeamId {
            let shown = pageFilter(for: currentItem).narrowed(by: filter)
            let states = snapshot.states(ofTeam: teamId).filter { state in
                (shown.stateCategories?.contains(state.category) ?? true) && (shown.stateIds?.contains(state.id) ?? true)
            }
            return BoardBuilder.stateColumns(items, states: states)
        }
        return BoardBuilder.categoryColumns(items, snapshot: snapshot)
    }

    private func loadDetail() {
        guard let store, let snapshot, let id = cursor ?? (selection.count == 1 ? selection.first : nil) else {
            detail = nil
            return
        }
        do {
            let next = try IssueDetail.load(id, store: store, snapshot: snapshot)
            if next != detail { detail = next }
        } catch {
            detail = nil
        }
    }

    private func watchForExternalChanges() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                await self?.runAutomations()
                self?.reloadIfChangedElsewhere()
            }
        }
    }

    private func reloadIfChangedElsewhere() {
        guard let store, let latest = try? store.latestChangeSeq(), latest != seenChangeSeq else { return }
        reloadAll()
        Self.log.info("Reloaded after external change, cursor \(latest), \(self.rowIds.count) issues")
    }

    // MARK: Layout

    var layout: ViewLayout { savedView?.layout ?? layouts[currentItem.storageKey] ?? .list }

    /// The one team whose workflow the board and the grouping follow, or nil when the list spans teams.
    var boardTeamId: String? {
        if let teamId = currentItem.teamId { return teamId }
        if case let .cycle(id) = currentItem { return snapshot?.cyclesById[id]?.teamId }
        guard case .view = currentItem, let teams = filter.teamIds, teams.count == 1 else { return nil }
        return teams.first
    }

    func toggleLayout() {
        let next: ViewLayout = layout == .board ? .list : .board
        if let view = savedView, let store, let user {
            do {
                try store.updateView(view.id, layout: next, by: user.id)
                reloadAll()
            } catch {
                showError(error)
            }
            return
        }
        layouts[currentItem.storageKey] = next
        UserDefaults.standard.set(layouts.mapValues(\.rawValue), forKey: Self.layoutsKey)
        reloadRows()
    }

    private static func loadLayouts() -> [String: ViewLayout] {
        let stored = UserDefaults.standard.dictionary(forKey: layoutsKey) as? [String: String] ?? [:]
        return stored.compactMapValues(ViewLayout.init(rawValue:))
    }

    // MARK: Selection

    /// Issues an action applies to: the selection, or the issue under the cursor.
    var targets: [String] {
        if !selection.isEmpty { return rowIds.filter(selection.contains) }
        return cursor.map { [$0] } ?? []
    }

    var issueCount: Int { rowIds.count }

    func select(_ ids: Set<String>, cursor newCursor: String?) {
        selection = ids
        cursor = newCursor ?? (ids.count == 1 ? ids.first : cursor)
        anchor = cursor
        loadDetail()
    }

    func focus(_ issueId: String) {
        if !rowIds.contains(issueId), let store, let issue = try? store.issue(issueId) {
            sidebarSelection = .team(issue.teamId, .all)
        }
        select([issueId], cursor: issueId)
        inspectorPresented = true
    }

    func moveCursor(by offset: Int, extend: Bool = false) {
        guard !rowIds.isEmpty else { return }
        let current = cursor.flatMap { rowIds.firstIndex(of: $0) }
        let target = current.map { min(max($0 + offset, 0), rowIds.count - 1) } ?? (offset > 0 ? 0 : rowIds.count - 1)
        let id = rowIds[target]
        if extend {
            let anchorIndex = anchor.flatMap { rowIds.firstIndex(of: $0) } ?? current ?? target
            let range = min(anchorIndex, target)...max(anchorIndex, target)
            selection = Set(rowIds[range])
            cursor = id
            loadDetail()
        } else {
            select([id], cursor: id)
        }
    }

    func toggleSelection() {
        guard let cursor else { return }
        if selection.contains(cursor) { selection.remove(cursor) } else { selection.insert(cursor) }
    }

    func clearSelection() {
        if overlay != nil { overlay = nil; return }
        selection = []
        cursor = nil
        loadDetail()
    }

    // MARK: Feedback

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 5 : 2.5))
            self?.toast = nil
        }
    }

    func showError(_ error: any Error) {
        showToast((error as? TrackaroError)?.description ?? error.localizedDescription, isError: true)
    }
}
