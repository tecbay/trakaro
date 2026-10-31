import Foundation
import TrackaroCore
import TrackaroKit

/// Filters on the current list, and saved views: a filter with a name in the sidebar.
///
/// Every sidebar item keeps its own filter. A saved view starts from the filter stored in the database; editing it
/// keeps the edit beside the view until it is saved to the view or discarded, the way unsaved changes work in
/// Linear. A page plus its filters can be saved as a new view that spans teams.
extension AppModel {
    private static let filtersKey = "filters"

    var savedView: SavedView? {
        guard case let .view(id) = currentItem else { return nil }
        return snapshot?.savedViewsById[id]
    }

    /// What the list is filtered by: the user's edit, else the saved view's own filter, else nothing.
    var filter: IssueFilter {
        filters[currentItem.storageKey] ?? savedView?.issueFilter ?? IssueFilter()
    }

    var isViewModified: Bool {
        guard let view = savedView, let edited = filters[currentItem.storageKey] else { return false }
        return edited != view.issueFilter
    }

    var filterBarVisible: Bool { !currentItem.isOverview && (!filter.isEmpty || savedView != nil || textFilterVisible) }

    var filterChips: [FilterChip] {
        guard let snapshot else { return [] }
        return FilterCatalog.chips(filter, snapshot: snapshot, userId: user?.id).filter { $0.dimension != .text }
    }

    var filterOptions: [FilterOption] {
        guard let snapshot else { return [] }
        return FilterCatalog.options(snapshot: snapshot, teamId: boardTeamId, userId: user?.id)
    }

    /// What a sidebar item shows before any filter, as a filter, so it can be saved into a view.
    func pageFilter(for item: SidebarItem) -> IssueFilter {
        switch item {
        case .myIssues:
            IssueFilter(stateCategories: StateCategory.allCases.filter(\.isOpen), assigneeIds: user.map { [$0.id] })
        case let .team(teamId, page):
            IssueFilter(teamIds: [teamId], stateCategories: page.categories)
        case let .project(id):
            IssueFilter(projectIds: [id])
        case let .cycle(id):
            IssueFilter(teamIds: snapshot?.cyclesById[id].map { [$0.teamId] })
        case .agentActivity, .view, .projects, .cycles:
            IssueFilter()
        }
    }

    /// The query a page shows before its filter: the page filter, plus the cycle a cycle page is limited to.
    func pageQuery(for item: SidebarItem) -> IssueQuery {
        var query = pageFilter(for: item).applied(to: IssueQuery(order: .manual, limit: TrackaroStore.maxPageSize))
        if case let .cycle(id) = item { query.cycle = .anyOf([id]) }
        return query
    }

    // MARK: Editing the filter

    func setFilter(_ next: IssueFilter) {
        let key = currentItem.storageKey
        let normalized = next.normalized
        if let view = savedView {
            filters[key] = normalized == view.issueFilter ? nil : normalized
        } else {
            filters[key] = normalized.isEmpty ? nil : normalized
        }
        persistFilters()
        reloadRows()
        if overlay == .filter { refreshOverlay() }
    }

    func toggleFilter(_ option: FilterOption) {
        setFilter(option.toggled(in: filter))
    }

    func clearFilter(_ dimension: FilterDimension) {
        setFilter(FilterCatalog.clearing(dimension, in: filter))
    }

    func clearFilters() {
        setFilter(IssueFilter())
        filterDraft = ""
        textFilterVisible = false
    }

    func setFilterText(_ text: String) {
        filterDraft = text
        var next = filter
        next.text = text
        setFilter(next)
    }

    /// Opens the filter picker, optionally already narrowed to one dimension.
    func openFilterPicker(query: String = "") {
        overlay = .filter
        overlayQuery = query
    }

    func focusFilterText() {
        textFilterVisible = true
        filterDraft = filter.text ?? ""
        filterFocusRequest += 1
    }

    func filterItems() -> [OverlayItem] {
        let filter = self.filter
        return filterOptions.map { option in
            OverlayItem(id: option.id, title: option.title, subtitle: option.dimension.title, symbol: symbol(for: option),
                        tint: tint(for: option), checked: option.isOn(in: filter), action: .filter(option))
        }
    }

    private func symbol(for option: FilterOption) -> String {
        switch option.dimension {
        case .text: "textformat"
        case .team: "person.3"
        case .category: "circle.dotted"
        case .status:
            option.values.first.flatMap { snapshot?.statesById[$0] }.map { Symbols.state($0.category) } ?? "circle"
        case .priority:
            option.values.first.flatMap(Int.init).flatMap(Priority.init(rawValue:)).map { Symbols.priority($0).name } ?? "minus"
        case .assignee:
            option.values.first.flatMap { snapshot?.membersById[$0] }?.kind == .agent ? "sparkles" : "person.crop.circle"
        case .label: "circle.fill"
        case .project: "cube"
        }
    }

    private func tint(for option: FilterOption) -> OverlayItem.Tint {
        let first = option.values.first
        switch option.dimension {
        case .status: return first.flatMap { snapshot?.statesById[$0] }.map { .hex($0.color) } ?? .secondary
        case .priority: return first.flatMap(Int.init).flatMap(Priority.init(rawValue:)).map { .priority($0) } ?? .secondary
        case .label: return first.flatMap { snapshot?.labelsById[$0] }.map { .hex($0.color) } ?? .secondary
        case .assignee: return first.flatMap { snapshot?.membersById[$0] }?.kind == .agent ? .agent : .secondary
        case .text, .team, .category, .project: return .secondary
        }
    }

    // MARK: Saved views

    func saveViewItems() -> [OverlayItem] {
        var items: [OverlayItem] = []
        if let view = savedView, isViewModified {
            items.append(OverlayItem(id: "update", title: "Update “\(view.name)”", subtitle: "Save these filters to the view",
                                     symbol: "square.and.arrow.down", action: .updateView))
        }
        let name = overlayQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            let summary = filterChips.map { "\($0.dimension.title): \($0.summary)" }.joined(separator: " · ")
            items.append(OverlayItem(id: "new", title: "Save as new view “\(name)”", subtitle: summary.isEmpty ? nil : summary,
                                     symbol: "plus.square.on.square", action: .saveView(name)))
        }
        return items
    }

    func saveView(named name: String) {
        guard let store, let user else { return }
        let source = currentItem
        let combined = pageFilter(for: source).narrowed(by: filter)
        do {
            let view = try store.createView(name: name, filter: combined, layout: layout, by: user.id)
            filters[source.storageKey] = nil
            persistFilters()
            reloadAll()
            sidebarSelection = .view(view.id)
            showToast("Saved view “\(view.name)”")
        } catch {
            showError(error)
        }
    }

    func updateCurrentView() {
        guard let store, let user, let view = savedView, isViewModified else { return }
        do {
            try store.updateView(view.id, filter: filter, by: user.id)
            filters[currentItem.storageKey] = nil
            persistFilters()
            reloadAll()
            showToast("Updated “\(view.name)”")
        } catch {
            showError(error)
        }
    }

    func revertView() {
        filters[currentItem.storageKey] = nil
        persistFilters()
        filterDraft = filter.text ?? ""
        reloadRows()
    }

    func deleteView(_ id: String) {
        guard let store, let user, let view = snapshot?.savedViewsById[id] else { return }
        do {
            try store.deleteView(id, by: user.id)
            filters[SidebarItem.view(id).storageKey] = nil
            persistFilters()
            if currentItem == .view(id) { sidebarSelection = .myIssues }
            reloadAll()
            showToast("Deleted view “\(view.name)”")
        } catch {
            showError(error)
        }
    }

    // MARK: Persistence

    static func loadFilters() -> [String: IssueFilter] {
        let stored = UserDefaults.standard.dictionary(forKey: filtersKey) as? [String: String] ?? [:]
        return stored.compactMapValues { try? IssueFilter(json: $0) }
    }

    private func persistFilters() {
        UserDefaults.standard.set(filters.mapValues(\.json), forKey: Self.filtersKey)
    }
}
