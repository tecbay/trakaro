# The macOS app (App/Trackaro)

SwiftUI, macOS 14+, built from `App/project.yml` by XcodeGen (the `.xcodeproj` is generated and not committed;
regenerate after adding or removing files). Not sandboxed, hardened runtime, ad-hoc signed. Bundle id
`app.trackaro.Trackaro`, URL scheme `trackaro`. No test target: logic belongs in Core or Kit.

## AppModel

`Model/AppModel.swift` is one `@MainActor @Observable` class, split by concern into extensions:

| File | Owns |
| --- | --- |
| `AppModel.swift` | Data (`snapshot`, `user`, `rows`, `rowsVersion`, `columns`, `detail`, `automations`, progress for planning pages), navigation (`sidebarSelection`, `currentItem`), selection and cursor, chrome flags, the poll loop, `reloadAll`, `reloadRows`, `boardColumns`, `layout` and `boardTeamId`, toasts |
| `AppModel+Commands.swift` | `OverlayItem`, `canPerform(_:)` and `perform(_:)` (exhaustive over `AppCommand`), palette items, property pickers, `refreshOverlay`, `confirmOverlay` |
| `AppModel+Editing.swift` | `edit(_:on:patch:)` (the one write path, records an undo batch), `setState`, `setPriority`, `setAssignee`, `setEstimate`, `setProject`, `setMilestone`, `setCycle`, `setDueDate`, title and description, labels, archive, `createIssue`, undo and redo, `defaultTeamId`, `defaultAssigneeId` |
| `AppModel+Board.swift` | Card cursor movement, column movement, `stepStatus`, `drop(_:on:before:)` |
| `AppModel+Filters.swift` | Per-page filters, saved views (save, update, revert, delete), `pageFilter(for:)`, `pageQuery(for:)`, filter picker items |
| `AppModel+Planning.swift` | `openProject`, `openCycle`, `currentCycle(teamId:)`, create project, milestone and cycle, update project, complete cycle with roll-over |
| `AppModel+Automations.swift` | Creating and ticking the `AutomationRunner`, run events to toasts, run now, stop, open log, save and delete rules |
| `AppModel+Artifacts.swift` | `goToArtifacts`, save and open a copy (an extension chosen from the kind), delete |
| `AppModel+Backups.swift` | `backupFolder`, the daily copy on launch, backup and restore panels, `restore(from:)` (suspends automations, then `resetAfterRestore`) |
| `AppModel+Links.swift` | `open(_ url:)` for every `AppLink` |
| `IssueDetail.swift` | Everything the inspector shows for one issue, loaded in one pass, including the last five automation runs |
| `Navigation.swift` | `SidebarItem` |

## Pages (SidebarItem)

`myIssues`, `agentActivity`, `team(teamId, .all | .active | .backlog)`, `view(savedViewId)`, `projects`,
`project(id)`, `artifacts(projectId or nil)`, `cycles(teamId)`, `cycle(id)`. Each has a `storageKey` (for per-page layout and filter), `title`,
`symbol` and `emptyMessage`. `isOverview` pages (`projects`, `cycles`, `artifacts`) show cards instead of an issue list and hide
the filter bar and layout picker.

To show issues, a page contributes `pageFilter(for:)` (an `IssueFilter`, also what "Save as view" captures) and
`pageQuery(for:)` (that filter as a query, plus the cycle constraint that `IssueFilter` cannot express). The
user's filter is applied on top with `filter.applied(to:)`. Agent activity is the exception: it lists
`recentChanges(by: .agent)` and filters those ids.

## Reload pipeline

1. `start()` opens the store, creates the `TASK` team on an empty database, `reloadAll()`, starts automations,
   starts the poll loop.
2. The poll loop (every 300 ms): `runAutomations()` ticks the runner, then `reloadIfChangedElsewhere()` reloads
   when `latestChangeSeq()` moved.
3. `reloadAll()`: snapshot, automations, then `reloadRows()`, `loadDetail()`, and the open overlay.
4. `reloadRows()`: query the page, build `ListRow`s (`IssueRowBuilder`, grouped by state, category or none) and
   board columns (`BoardBuilder.stateColumns` for one team, `categoryColumns` across teams), and bump
   `rowsVersion` only when something differs. `IssueTableView` redraws only on a `rowsVersion` change.
5. Local edits call `reloadAll()` themselves after writing.

Rows note which agent changed an issue in the last 15 minutes (`recentAgentWindow`).

## Keyboard, palette and pickers

- `Keyboard/KeyboardController.swift` installs a local `NSEvent` monitor. With an overlay open it handles
  arrows, Return, Escape and Ctrl-N/P. Otherwise it feeds `ChordMatcher` (in Kit) with `AppCommand.catalog` and
  calls `model.perform`. Text fields keep their keys unless a command is `worksInTextFields`. Plain arrows go to
  a focused `NSTableView`. Sheets own the keyboard.
- `AppCommand` (Kit) is the single list: title, section, binding, scope, palette visibility. A command without a
  binding must be in the palette (a test enforces this). `AppCommand.sections` orders the shortcuts sheet; add a
  new section name there.
- Overlays (`AppModel.Overlay`): `palette`, `picker(status | priority | assignee | labels | estimate)`,
  `filter`, `saveView`, `shortcuts`. Palette, pickers, filter and save view all render in `CommandMenuView`
  (`OverlayViews.swift`) from `overlayItems`, ranked by `FuzzyMatch`. A picker captures `pickerTargets` when it
  opens. Label and filter pickers stay open on Return so several values can be toggled.

## Views

- `RootView.swift`: `NavigationSplitView` with `SidebarView` and `IssueListPane` plus an `.inspector`. The pane
  switches between overview pages, `BoardView`, empty states and `IssueTableView`, with a top inset stack of
  `ProjectHeader`, `CycleHeader` and `FilterBar`. Sheets: quick create, automations, new project. The
  complete-cycle confirmation dialog lives here.
- `IssueTableView.swift`: `NSTableView` wrapper with reused AppKit cells. Keep it AppKit.
- `BoardView.swift`: columns with drag and drop (`draggable` ids, insertion markers), `matchedGeometryEffect`
  so agent moves animate, a lightning mark and "Automate this column…" menu on automated column headers.
- `InspectorView.swift`: title, properties grid (Milestone appears when the project has milestones), description,
  links, automation runs (Stop, Log), activity and comments feed, composer.
- `FilterBar.swift`, `PlanningViews.swift` (progress bar, project and cycle overviews and headers, burn-up chart
  with Swift Charts, new project sheet), `AutomationsView.swift`, `QuickCreateView.swift` (defaults its team,
  state, assignee, project and cycle from the current page), `ConnectAgentView.swift` (one-click MCP setup over
  `AgentConnector` in Kit, opened by the sidebar button or the `connectAgent` command).
- `MarkdownView.swift`: `MarkdownView` draws `Markdown.blocks` from Kit, used for descriptions, comments and artifacts.
  `MarkdownEditor` wraps `NSTextView` because the toolbar needs the selection, which `TextEditor` lacks on macOS 14.
  `DescriptionSection` reads, edits and warns when an agent changes the text mid-edit; it saves on Done or on leaving
  the issue. The larger sheet adds a live preview.
- `ArtifactsView.swift`: `ArtifactsPage` is a list and a viewer by kind: Markdown, `SafeHTMLView` (scripts off, remote
  loads blocked), `PlainTextViewer`, image, `PDFViewer`, or save-only. The inspector is hidden on this page.
- `BackupsView.swift`: back up, restore from a file, or restore an automatic copy.
- `Design/Theme.swift`: colour tokens (`Theme.accent`, `agent`, `danger`, `high`, state and priority colours),
  `Symbols`, `RelativeTime`. No literal colours in views.

## Automations in the app

`AppModel+Automations.startAutomations` builds an `AutomationRunner` with the log folder next to the database
(`automation-logs/`) and the database path so spawned agents use the same file. The runner marks runs left
running by a previous app as `interrupted`, then each tick reads the feed from the moment the app started, asks
`AutomationMatcher` what the user's moves trigger, and launches `zsh -l -c <command>` in the rule's folder with
`TRACKARO_PROMPT`, `TRACKARO_ISSUE`, `TRACKARO_TITLE`, `TRACKARO_URL` and `TRACKARO_DATABASE`. Run events come
back as toasts and a reload. Quitting the app does not kill running agents; their runs show as interrupted on the
next launch.

## Persisted preferences (UserDefaults, domain app.trackaro.Trackaro)

`layouts` (list or board per page storage key; saved views store their layout in the database instead),
`filters` (`IssueFilter` JSON per page; for a saved view, the unsaved edit), `appearance` (system, light, dark;
`defaults write app.trackaro.Trackaro appearance dark` to force it).

## Deep links

`AppLink` (Kit) parses and `AppModel+Links` acts: `issue/ENG-1`, `my-issues`, `agent-activity`,
`team/ENG[/active|/backlog]`, `view/<name or id>`, `projects`, `project/<slug, name or id>`, `artifacts[/<project>]`,
`artifact/<project>/<name>`, `cycles/ENG`,
`cycle/ENG/<number or current>`, `command/<AppCommand rawValue>`. Unknown links show an error toast.
