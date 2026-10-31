# Trackaro

Local-first, keyboard-first task manager for macOS, built so coding agents (Claude Code, Cursor) can read and
change tasks through an MCP server. Native SwiftUI over a UI-free Swift core. Local only: no accounts, no server.

## Layout

```
Package.swift            TrackaroCore, TrackaroKit, TrackaroMCP, the trackaro-mcp executable, and their tests
Sources/TrackaroCore     Domain model, schema, store, ordering, queries
Sources/TrackaroMCP      MCP tools, resources, prompts (official swift-sdk, pinned exactly)
Sources/TrackaroKit      UI logic with no UI: key bindings and chords, the command catalog, fuzzy matching,
                         undo history, list rows, activity text, deep links
Sources/trackaro-mcp     stdio entry point
Tests/TrackaroCoreTests  Swift Testing suites, mirroring Sources
Tests/TrackaroKitTests   Tests for TrackaroKit
Tests/TrackaroMCPTests   Tests through a real MCP Client over InMemoryTransport (see Support/Harness.swift)
App/project.yml          XcodeGen spec for the macOS app (the .xcodeproj is generated, not committed)
App/Trackaro             SwiftUI app: Model (AppModel and extensions), Views, Keyboard, Design
scripts/make-icon.swift  Draws the app icon into App/Trackaro/Assets.xcassets
scripts/make-dmg.sh      Builds the universal app with trackaro-mcp inside and packs dist/Trackaro-<version>.dmg
```

For the architecture map, data flows, change recipes and the on-screen verification routine, use the
`trackaro-architecture` skill in `.claude/skills/`. Keep it current when structure changes.

## Commands

```
swift build                                   build the core
swift test                                    run all tests (Core, Kit, MCP)
cd App && xcodegen generate                   regenerate Trackaro.xcodeproj after editing project.yml
xcodebuild -project App/Trackaro.xcodeproj -scheme Trackaro -derivedDataPath .build/xcode build
swift build -c release --product trackaro-mcp  build the MCP server binary
scripts/make-dmg.sh                           build dist/Trackaro-<version>.dmg (ad hoc signed unless SIGN_IDENTITY is set)
```

The database lives at `~/Library/Application Support/Trackaro/trackaro.sqlite`. Both the app and `trackaro-mcp`
honour `TRACKARO_DATABASE`; use it for any manual testing so real data is never touched.

Drive the running app from the shell with deep links, which is also how to take screenshots of a given state:
`open "trackaro://issue/ENG-1"`, `open "trackaro://team/ENG/active"`, `open "trackaro://command/palette"`.
Synthetic keystrokes need Accessibility permission, so test keyboard behaviour through `ChordMatcher` tests.
Force an appearance with `defaults write app.trackaro.Trackaro appearance dark` (and `defaults delete` after).

In zsh, `log` is a shell builtin. Read the app's logs with `/usr/bin/log stream --level info --predicate
'subsystem == "app.trackaro.Trackaro"'`.

## Rules

- **All reads and writes go through `TrackaroStore`.** UI and MCP never write SQL. Every write runs in one
  transaction that also records issue activity and appends to `changeLog`.
- **Errors are `TrackaroError`.** `notFound`, `invalid(field:)`, `conflict` (stale expectation or an ambiguous
  reference). Messages are written for a human or an agent to act on.
- **References are forgiving.** Issues resolve by id, identifier (`ENG-42`, any case) or a pre-move alias. Teams
  resolve by id, key or name. Ambiguity is a `conflict` that lists candidates.
- **Partial updates use `IssuePatch`.** A nil property leaves the field alone, `FieldUpdate.clear` empties it.
  Pass the last-read values as `expecting:` for compare-and-set; undo must always do this.
- **Ordering is fractional.** `sortKey` is a base-62 fractional index (`FractionalIndex`), compared bytewise.
  A move rewrites one row. Never renumber a column.
- **Identifiers are never reused.** `team.issueCounter` only grows. Changing team issues a new identifier and keeps
  the old one in `issueAlias`.
- **State timestamps follow `StateTimestamps.entering`.** Do not set `startedAt`, `completedAt` or `canceledAt` by hand.
- **Schema changes are new migrations** in `Schema.swift`. Never edit a shipped migration.
- **Two processes, one file.** The app and `trackaro-mcp` share the database in WAL mode with a busy timeout. The
  app notices other writers by polling `latestChangeSeq()`. Never cache data across that boundary.

## App rules

- **One command list.** Every shortcut, palette entry, overlay row and context menu item comes from
  `AppCommand`. Adding a command means a case there and an arm in `AppModel.perform`; the switch is exhaustive.
- **The keyboard controller owns keys.** A local `NSEvent` monitor routes presses through `ChordMatcher` before
  AppKit sees them. Text fields keep their keys except commands marked `worksInTextFields`.
- **Every edit is undoable.** Writes go through `AppModel.edit(_:on:patch:)` or record an `EditBatch` themselves.
  Undo uses compare-and-set, so it refuses rather than overwrite an agent's newer change.
- **The list is AppKit.** `IssueTableView` wraps `NSTableView` with reused cells and reloads only when
  `rowsVersion` changes. Do not replace it with a SwiftUI `List`.
- **One filter type.** `IssueFilter` (core) is the filter bar's state, a saved view's stored JSON and what
  `search_issues` and `save_view` build from arguments. It only narrows: `applied(to:)` intersects with the page's
  own query, and `narrowed(by:)` folds a page into a filter when saving a view. Options and chips come from
  `FilterCatalog` in TrackaroKit.
- **Automations run shell commands, so they stay the user's.** Only the app creates them; there is no MCP tool.
  `AutomationMatcher` fires on the user's moves only, never an agent's. Issue text reaches the command through
  `TRACKARO_*` environment variables and is never spliced into the command string; keep it that way, and keep
  `runnerRunsTheCommandWithIssueTextOnlyInTheEnvironment` passing.
- **Colors come from `Theme` or the system.** No literal colors in views.

## MCP tool design

- **Names in, names out.** Tools accept `ENG-42`, state and label names, `"me"` (the user) and `"self"` (the agent),
  resolved in `Resolver`. Output shows names, never bare ids, except an issue's own `id`.
- **Misses teach.** A name that matches nothing throws `TrackaroError.noMatch` with the valid options.
- **Omitted stays, null clears.** Same rule in every tool, implemented once in `IssueTools.patch`.
- **Validate before writing.** Batch tools resolve every item first, so a bad name writes nothing.
- **Compact output.** `ObjectBuilder` drops empty fields; `Output.render` is minified JSON. Listing tools return
  summaries; `get_issues` is the only full-detail read.
- **stdout is the protocol.** `trackaro-mcp` writes nothing else there. Diagnostics go to stderr.
- **Agent pings report only what the user did.** `AgentFeed` filters the change feed to `MemberKind.user` and
  excludes the calling agent, so agents never react to their own or each other's changes. Hook output formats
  in `AgentFeed.render` must match the Claude Code and Cursor docs exactly; see docs/agent-pings.md.
- **Every tool is tested through `Harness`**, a real MCP `Client`. `advertisesToolsWithAnnotationsAndStrictSchemas`
  pins the read-only set; update it deliberately when adding a tool.
- **Strict concurrency.** Swift 6 language mode. Records are `Sendable` value types; the store is `Sendable`.
- **Tests.** Every rule gets a test that would fail if the rule broke. Use `Fixture` and its stepping clock.
- **Performance budget.** Cold launch under 300 ms, command palette under 50 ms, search under 50 ms on 50k issues,
  MCP round trip under 20 ms. Index anything a list or the MCP server filters on.
