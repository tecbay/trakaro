# Trackaro

A fast, local, keyboard-first task manager for macOS that coding agents can drive over MCP.

## Status

Phase 1 (foundation) is in place:

- SQLite schema: teams, workflow states, issues, labels, relations, comments, activity, projects, milestones,
  cycles, saved views, a change log, and full-text search.
- Issue rules: `KEY-n` identifiers from a per-team counter, seven state categories with lifecycle timestamps,
  fractional ordering, sub-issues with cycle checks, inverse relations, compare-and-set updates, team moves with
  identifier aliases.
- A minimal SwiftUI window that opens the database, adds issues and moves them between states.

## Build

Requires Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
swift test
cd App && xcodegen generate && open Trackaro.xcodeproj
```

## Roadmap

1. Foundation (done)
2. MCP server for Claude Code and Cursor
3. Core UI: sidebar, list, inspector, keyboard registry, command palette
4. Planning: board, filters, saved views, cycles, projects
5. Notes, local inbox and reminders, release signing
