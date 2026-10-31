---
name: trackaro-architecture
description: Architecture map, data flows, change recipes and verification routine for Trackaro, the native macOS task manager with an MCP server for coding agents (repository /Users/home/code/trackaro). Use whenever working in that repository: adding or changing a feature, a database field, an MCP tool, an app page or command, an automation, fixing a bug, or answering how some part of Trackaro works. Read it before exploring the code; it says where things live so you do not have to search.
---

# Trackaro architecture

Trackaro is a local-only, keyboard-first task manager for macOS (Linear-style: teams, workflow states, issues,
projects, cycles, views) whose main purpose is letting coding agents read and change tasks through MCP. Swift 6,
SwiftUI app over a UI-free Swift core, one SQLite file shared by two processes.

`CLAUDE.md` in the repository holds the rules (store-only writes, `IssuePatch`, fractional ordering, MCP tool
design, app rules). This skill holds the map. Follow both.

## The four layers

```
TrackaroCore   GRDB store over SQLite. Records, schema migrations, every read and write, queries,
               IssueFilter, change log and feed, progress, saved views, automations. No UI, no MCP.
TrackaroKit    UI logic with no UI: AppCommand catalog, ChordMatcher, FuzzyMatch, EditHistory (undo),
               list rows and board columns, filter options and chips, cycle timing and burn-up,
               deep links (AppLink), AutomationMatcher and AutomationRunner. Depends on Core.
TrackaroMCP    MCP server: ToolKit, Resolver (names to ids), Presenter (records to compact JSON),
               tools, resources, prompts, AgentFeed, ChannelTransport. Depends on Core and Kit.
trackaro-mcp   stdio executable: server mode, `watch`, `pending`. Depends on Core and MCP.
App/Trackaro   SwiftUI app built by XcodeGen. AppModel (@Observable, @MainActor) split into
               extensions, Views, KeyboardController, Theme. Depends on Core and Kit.
```

Put logic as low as it can go. Anything testable without a window belongs in Core or Kit, with a test there.
The app target has no test target; app code should be thin glue over tested Core and Kit pieces.

## Two processes, one database

```
Trackaro.app ──writes──┐                     ┌──writes── trackaro-mcp (one per agent session)
   │ polls every 300 ms │   trackaro.sqlite   │  stdio JSON-RPC to Claude Code / Cursor
   │ latestChangeSeq()  └──► WAL, changeLog ◄─┘  channel pump polls the feed every 700 ms
   ▼
 reloadAll ─► snapshot + automations ─► reloadRows ─► rows / columns (rowsVersion bump only on change)
```

- Every write goes through `TrackaroStore` in one transaction that appends to `changeLog` (any model) and, for
  issues, `issueActivity`. `latestChangeSeq()` is the app's cheap "did anything change" check.
- `feed(after:memberKinds:excludingMember:)` reads `issueActivity` and `comment` rows after a `FeedCursor`
  (`activity:comment`). Agent pings (`AgentFeed`), the channel push and automations all read it, filtered to
  `MemberKind.user` so agents never react to agents.
- Each MCP session records its writes as an agent member named from the client (`Claude Code`, `Cursor`) or
  `--agent-name`. "me" is the local user, "self" is the agent.

## Where each feature lives

| Feature | Core | Kit | MCP | App |
| --- | --- | --- | --- | --- |
| Issues, states, labels, relations, comments | `TrackaroStore+Issues.swift`, `+Moves`, `+Relations`, `+Teams`, `Model/Records.swift` | `IssueRows.swift`, `ActivityFormatter.swift` | `Tools/IssueTools.swift`, `ConversationTools.swift` | `IssueTableView`, `InspectorView`, `AppModel+Editing` |
| Board | `Store/TrackaroStore+Moves.swift` | `Presentation/Board.swift` | `move_issue` | `BoardView`, `AppModel+Board` |
| Filters and saved views | `Store/IssueFilter.swift`, `TrackaroStore+Views.swift` | `Presentation/Filters.swift` | `Tools/ViewTools.swift`, `search_issues view` | `FilterBar`, `AppModel+Filters` |
| Projects, milestones, cycles | `TrackaroStore+Planning.swift`, `TrackaroStore+Progress.swift` | `Presentation/Planning.swift` | `Tools/PlanningTools.swift` | `PlanningViews`, `AppModel+Planning` |
| Agent pings | `TrackaroStore+Feed.swift` | | `AgentFeed.swift`, `ChannelTransport.swift`, `main.swift` | |
| Column automations | `Model/Automation.swift`, `TrackaroStore+Automations.swift` | `Automation/AutomationMatcher.swift`, `AutomationRunner.swift` | none, on purpose | `AutomationsView`, `AppModel+Automations` |
| Keyboard, palette, pickers | | `Keyboard/*`, `Search/FuzzyMatch.swift` | | `KeyboardController`, `AppModel+Commands`, `OverlayViews` |
| Undo and redo | compare-and-set via `expecting:` | `Editing/EditHistory.swift` | | `AppModel+Editing` |
| Deep links | | `Navigation/AppLink.swift` | | `AppModel+Links` |

## Reference files

Read the one that matches the task; each is self-contained.

- [references/data-model.md](references/data-model.md): tables, records, enums, queries and `IssueFilter`,
  progress, feed and change log, migrations.
- [references/mcp-server.md](references/mcp-server.md): the 26 tools by area, ToolKit, Resolver and Presenter,
  resources and prompts, channel push and hook CLI, the test harness.
- [references/app.md](references/app.md): AppModel and its extensions, sidebar pages and the reload pipeline,
  keyboard and overlays, board, filter bar, planning pages, automations runner, persisted preferences.
- [references/recipes.md](references/recipes.md): step-by-step changes (new issue field, migration, MCP tool,
  command, sidebar page, deep link), and the routine for verifying on screen.

## Build, test, run

```
swift build                                    Core, Kit, MCP, trackaro-mcp
swift test                                     all three test targets; three "Test run with N tests" lines, add them up
cd App && xcodegen generate                    after adding or removing app source files, or editing project.yml
xcodebuild -project App/Trackaro.xcodeproj -scheme Trackaro -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Trackaro.app            the user's normal way to open it today
swift build -c release --product trackaro-mcp && install -m 755 .build/release/trackaro-mcp ~/.local/bin/trackaro-mcp
scripts/make-dmg.sh                            dist/Trackaro-<version>.dmg, with trackaro-mcp in Contents/Helpers
```

The user's Claude Code has `trackaro` registered at user scope as `~/.local/bin/trackaro-mcp --channel`.
Reinstall the binary after MCP or schema changes so the agent side matches the app; that changes the user's
machine, so say so. `claude mcp list` confirms it connects.

## Verifying a change

Tests first. For anything visible, run the app against a scratch database, never the user's:
`TRACKARO_DATABASE=<scratchpad>/x.sqlite .build/xcode/.../Contents/MacOS/Trackaro &`. The full routine (seeding
through MCP, driving the app with deep links, capturing only Trackaro's window, simulating a user move) is in
[references/recipes.md](references/recipes.md#verify-on-screen). Key limits:

- No Accessibility permission: no synthetic clicks or keys. Drive state with `trackaro://` deep links, including
  `trackaro://command/<AppCommand>`. Say plainly what could not be clicked through.
- The user may be using the Mac. Capture only Trackaro's window (`screencapture -l <window id>`), never the full
  screen, and quit and reopen the user's instance around a test rather than leaving it closed.
- Changes made through MCP are agent changes. They do not trigger automations or agent pings. A user move is
  `open trackaro://issue/ENG-1` then `open trackaro://command/moveToNextStatus`.

## Status

Done: core store, MCP server (26 tools, 3 resources, 3 prompts), list and inspector UI, palette and keyboard
layer, board, filters and saved views, projects and cycles pages, agent pings (channel push, hooks, watch), column
automations, `.dmg` build. Not yet: Cursor setup and installed hooks, notes, an agent inbox, Developer ID signing
and a downloadable release. `README.md` keeps the user-facing status list; update it with each feature.
