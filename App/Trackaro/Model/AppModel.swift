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
    private(set) var detail: IssueDetail?
    private(set) var loadError: String?

    // MARK: Navigation and selection

    var sidebarSelection: SidebarItem? = .myIssues {
        didSet {
            guard sidebarSelection != oldValue else { return }
            selection = []
            cursor = nil
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
        } catch {
            showError(error)
        }
        if case let .team(id, _) = currentItem, snapshot?.teamsById[id] == nil {
            sidebarSelection = .myIssues
        }
        reloadRows()
        loadDetail()
        if overlay != nil { refreshOverlay() }
    }

    private func reloadRows() {
        guard let store, let snapshot, let user else { return }
        do {
            let issues: [Issue]
            var notes: [String: String] = [:]
            var grouping = ListGrouping.state
            switch currentItem {
            case .myIssues:
                issues = try store.queryIssues(IssueQuery(
                    stateCategories: StateCategory.allCases.filter(\.isOpen), assignee: .anyOf([user.id]),
                    order: .manual, limit: TrackaroStore.maxPageSize
                )).issues
                grouping = .category
            case .agentActivity:
                let changes = try store.recentChanges(by: .agent)
                issues = changes.map(\.issue)
                for change in changes { notes[change.issue.id] = "\(change.member.name) · \(RelativeTime.string(change.at))" }
                grouping = .none
            case let .team(teamId, page):
                issues = try store.queryIssues(IssueQuery(
                    teamIds: [teamId], stateCategories: page.categories, order: .manual, limit: TrackaroStore.maxPageSize
                )).issues
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
        if case let .team(teamId, page) = currentItem {
            let states = snapshot.states(ofTeam: teamId).filter { page.categories?.contains($0.category) ?? true }
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

    var layout: ViewLayout { layouts[currentItem.storageKey] ?? .list }

    func toggleLayout() {
        layouts[currentItem.storageKey] = layout == .board ? .list : .board
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
