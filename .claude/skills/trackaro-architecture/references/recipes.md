# Recipes

Each recipe lists every place a change has to reach. Work bottom up (Core, Kit, MCP, App) and test each layer
before the next.

## The enum CHECK trap

These columns have CHECK constraints listing an enum's cases: `member.kind` (`MemberKind`),
`workflowState.category` (`StateCategory`), `project.status` and `health`, `issueRelation.type`
(`RelationType`), `issueActivity.field` (`IssueField`), `savedView.layout` (`ViewLayout`), `changeLog.action`
(`ChangeAction`), `automationRun.status` (`AutomationRunStatus`).

The migrations build the list from `allCases` when they run. So adding an enum case passes every test (a fresh
in-memory database runs the migration with the new case) and then fails on every existing database, including
the user's, because its stored CHECK still has the old list. Adding a case therefore needs a new migration that
rebuilds the table with the wider CHECK (SQLite cannot alter a CHECK): create the new table, copy rows, drop the
old one, rename, recreate indexes and triggers. Test it by opening a database created before the change, not
only an in-memory one.

## Add a field to issues

1. Migration in `Schema.swift`: `ALTER TABLE issue ADD COLUMN ...` in a new `registerMigration`. Index it if lists
   or MCP filter on it. If it is searchable text, the FTS table and triggers need a rebuild too.
2. `Issue` in `Model/Records.swift`; `NewIssue` and `IssuePatch` in `Store/IssueInputs.swift` (`FieldUpdate` for
   optional fields).
3. `TrackaroStore+Issues.swift`: set it in `createIssue`, apply it in `updateIssue` with a `FieldDelta` so
   activity is recorded. A new `IssueField` case hits the CHECK trap above.
4. Kit: `ActivityFormatter.describe` for the activity line; `IssueRowItem`, `IssueRowBuilder` if rows show it;
   the `IssueEdit` switch in `Editing/EditHistory.swift` that maps each `IssueField` back to an `IssuePatch`, or undo will silently skip the field.
5. MCP: `IssueTools.editableFields` (schema), `IssueTools.patch` (omitted keeps, null clears), `Presenter` output,
   `create_issue` and `bulk_update_issues` if relevant. Test through `Harness`.
6. App: a `set...` in `AppModel+Editing` via `edit(_:on:patch:)`, a `PropertyRow` in `InspectorView`, optionally a
   picker (`PickerKind`, `pickerItems`) and an `AppCommand`.

## Add a table or other schema change

New `registerMigration("vN-name")` in `Schema.swift`, a record in `Model/`, store functions in a new
`TrackaroStore+Thing.swift` that write inside `writer.write`, call `requireMember`, and `recordChange(db, model:
"thing", ...)` so the app notices. Add it to `WorkspaceSnapshot` only if it is small reference data the UI shows
everywhere. Then rebuild and reinstall `trackaro-mcp` so both processes know the migration.

## Add an MCP tool

1. A `ToolDefinition` in the matching `Tools/*.swift` and its area's `all` list (or a new area added to
   `TrackaroMCPServer.allTools`). Strict `JSONSchema.object`, `readOnly`, `destructive` where it deletes.
2. Resolve every name with `Resolver` before writing; throw `noMatch` with options; write as `context.agent.id`.
3. Output through `Presenter` and `ObjectBuilder`, names not ids.
4. Tests through `Harness`: the happy path, a teaching failure, and the read-only set in
   `advertisesToolsWithAnnotationsAndStrictSchemas` if the tool is read-only.
5. Update the tool table in `README.md`, the count in this skill, and `get_workspace` or `Instructions` if agents
   need to discover it. Reinstall the binary.

## Add an app command

1. A case in `AppCommand` (Kit) with title, section (listed in `AppCommand.sections`), binding or `nil`
   (palette only), scope (`.list` for issue actions). `KeyboardTests` checks for binding conflicts.
2. `canPerform` and `perform` arms in `AppModel+Commands.swift` (both switches are exhaustive).
3. Optionally a menu item in `TrackaroApp.swift`. It is reachable as `trackaro://command/<rawValue>` for testing.

## Add a sidebar page

1. A case in `SidebarItem` (`Navigation.swift`) with `storageKey`, `title`, `symbol`, `emptyMessage`, and
   `teamId`/`isOverview` if they apply.
2. `pageFilter(for:)` and, if needed, `pageQuery(for:)` in `AppModel+Filters.swift`.
3. A case in `reloadRows()` (query, grouping, any page data such as progress), and in `boardTeamId` if the page
   belongs to one team.
4. The sidebar in `RootView.swift`, the palette places in `paletteItems()`, the fallback in `reloadAll()` when the
   item no longer exists, and optionally an `AppLink` case.

## Add a deep link

`AppLink` case and parser in Kit with a row in `AppLinkTests`, then an arm in `AppModel+Links.open`. Unknown
references show an error toast; never fail silently.

## Verify on screen

Use a scratch database in the scratchpad directory, never the user's.

1. Build: `swift build --product trackaro-mcp` and the `xcodebuild` command in SKILL.md (run `xcodegen generate`
   first if files were added).
2. Seed it through the MCP server, which also exercises the tools. Pipe JSON-RPC lines into
   `.build/debug/trackaro-mcp --database $DB`: an `initialize` request, a `notifications/initialized` notification,
   then `tools/call` requests, reading one response line per request. A short Python `subprocess` script does this
   well. Everything seeded this way is an agent change.
3. If the user has Trackaro open, quit it first (`osascript -e 'tell application "Trackaro" to quit'`); two
   instances make deep links ambiguous. Tell the user, and reopen theirs at the end with
   `open -g .build/xcode/Build/Products/Debug/Trackaro.app`.
4. Launch on the scratch database: `TRACKARO_DATABASE=$DB nohup .build/xcode/Build/Products/Debug/Trackaro.app/Contents/MacOS/Trackaro > $LOG 2>&1 &`.
5. Drive it with `open -g "trackaro://..."` (the `-g` keeps it from stealing focus). Select then act:
   `trackaro://issue/ENG-7` followed by `trackaro://command/moveToNextStatus` is a real user move, which is what
   triggers automations and agent pings.
6. Capture only Trackaro's window. Find its window number with a small Swift script using
   `CGWindowListCopyWindowInfo` (owner name "Trackaro", layer 0, height over 300), then
   `screencapture -x -o -l $WINDOW out.png` and `sips -Z 1400` before reading it. Never capture the full screen:
   the user may be using the Mac, and a full capture shows whatever else is on it.
7. Check data directly when useful: `sqlite3 $DB "select ..."`. Dates are stored as UTC text
   `yyyy-MM-dd HH:mm:ss.SSS`; rows inserted by hand do not appear in `changeLog`, so the app only notices them on
   its next reload.
8. Say what was not verified: anything that needs a click, typing, drag and drop or a menu, since there is no
   Accessibility permission.

## Ship it to the user

1. `swift test` green (sum the three "Test run with" lines) and the app builds.
2. Commit (git identity is repo-local; the user allows committing finished, tested work without asking; never
   push without asking).
3. If MCP or the schema changed: `swift build -c release --product trackaro-mcp` and
   `install -m 755 .build/release/trackaro-mcp ~/.local/bin/trackaro-mcp`, then `claude mcp list`. Tell the user;
   running Claude Code sessions keep the old server until restarted.
4. The user's running app keeps old code until relaunched; tell them to quit and reopen it, or do it around a
   check as above.
5. Update `README.md` status and, when structure changed, this skill.

## Gotchas

- Manual order inside a state is not creation order; compare sets in tests unless order is the point.
- MCP changes are agent changes: they never trigger automations or pings. Use a deep-link user move.
- `swift test --filter` takes a regex over suite and test names; `ViewTests|QueryTests` works.
- `sed -i ''` on macOS; `log` is a zsh builtin (use `/usr/bin/log`).
- `IssueFilter` normalises: blank text and empty lists become nil, so bind text fields to a separate draft
  (`filterDraft`) or trailing spaces vanish as the user types.
- A `@MainActor` model cannot be captured in a `@Sendable` closure directly; hop with `Task { @MainActor in ... }`
  as `startAutomations` does.
- Process spawning: pass issue text as environment variables only. `AutomationTests` proves `$(...)` in a title
  stays inert; keep that test.
