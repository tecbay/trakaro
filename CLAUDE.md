# Trackaro

Local-first, keyboard-first task manager for macOS, built so coding agents (Claude Code, Cursor) can read and
change tasks through an MCP server. Native SwiftUI over a UI-free Swift core. Local only: no accounts, no server.

## Layout

```
Package.swift          TrackaroCore library (SQLite through GRDB) and its tests
Sources/TrackaroCore   Domain model, schema, store, ordering
Tests/TrackaroCoreTests  Swift Testing suites, mirroring Sources
App/project.yml        XcodeGen spec for the macOS app (the .xcodeproj is generated, not committed)
App/Trackaro           SwiftUI app
```

Planned next: a `TrackaroMCP` server target (phase 2), then the full UI (phases 3 to 5).

## Commands

```
swift build                                   build the core
swift test                                    run all core tests
cd App && xcodegen generate                   regenerate Trackaro.xcodeproj after editing project.yml
xcodebuild -project App/Trackaro.xcodeproj -scheme Trackaro -derivedDataPath .build/xcode build
```

The app's database lives at `~/Library/Application Support/Trackaro/trackaro.sqlite`.

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
- **Strict concurrency.** Swift 6 language mode. Records are `Sendable` value types; the store is `Sendable`.
- **Tests.** Every rule gets a test that would fail if the rule broke. Use `Fixture` and its stepping clock.
- **Performance budget.** Cold launch under 300 ms, command palette under 50 ms, search under 50 ms on 50k issues,
  MCP round trip under 20 ms. Index anything a list or the MCP server filters on.
