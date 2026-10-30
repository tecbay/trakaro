# Trackaro

A fast, local, keyboard-first task manager for macOS that coding agents can drive over MCP.

## Status

- **Phase 1, foundation (done).** SQLite store with teams, workflow states, issues, labels, relations, comments,
  activity history, projects, milestones, cycles, saved views, a change log and full-text search. Issue rules:
  `KEY-n` identifiers that are never reused, lifecycle timestamps, fractional ordering, sub-issues, inverse
  relations, compare-and-set updates, team moves that keep the old identifier working.
- **Phase 2, MCP server (done).** `trackaro-mcp` exposes 23 tools, 3 resources and 3 prompts over stdio. Agents
  use names (`ENG-42`, `"In Progress"`, `"me"`), every change is recorded under the agent's name, and the app
  shows agent edits live.
- **Phase 1 app shell.** A minimal SwiftUI window: quick add, issues grouped by state, move between states.

## Build

Requires Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
swift test
cd App && xcodegen generate && open Trackaro.xcodeproj
```

## Connect a coding agent

Build the server once:

```
swift build -c release --product trackaro-mcp
install -m 755 .build/release/trackaro-mcp ~/.local/bin/trackaro-mcp
```

Claude Code:

```
claude mcp add --scope user trackaro -- ~/.local/bin/trackaro-mcp
```

Cursor, in `~/.cursor/mcp.json`:

```json
{ "mcpServers": { "trackaro": { "command": "/Users/YOU/.local/bin/trackaro-mcp" } } }
```

Options: `--read-only` hides every tool that writes, `--agent-name "Claude (backend)"` records changes under a
custom name, `--database PATH` (or `TRACKARO_DATABASE`) points at another database file.

The server opens the same database as the app, so agents can work whether or not the app is running, and the app
picks up their changes within a third of a second.

### Tools

| Area | Tools |
| --- | --- |
| Orientation | `get_workspace` |
| Issues | `search_issues`, `get_issues`, `create_issue`, `create_sub_issues`, `update_issue`, `move_issue`, `bulk_update_issues`, `archive_issue` |
| Conversation | `add_comment`, `list_comments`, `get_issue_history`, `set_relation`, `remove_relation`, `mark_duplicate` |
| Planning | `list_projects`, `create_project`, `create_milestone`, `list_cycles`, `create_cycle`, `cycle_progress` |
| Setup | `create_label`, `create_team` |

Resources: `trackaro://workspace`, `trackaro://cycles/active`, `trackaro://issue/{identifier}`.
Prompts: `standup`, `triage`, `plan_work`.

## Roadmap

1. Foundation (done)
2. MCP server (done)
3. Core UI: sidebar, list, inspector, keyboard registry, command palette
4. Planning: board, filters, saved views, cycles, projects
5. Notes, local inbox and reminders, release signing
