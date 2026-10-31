# Trackaro

A fast, local, keyboard-first task manager for macOS that coding agents can drive over MCP.

## Status

- **Phase 1, foundation (done).** SQLite store with teams, workflow states, issues, labels, relations, comments,
  activity history, projects, milestones, cycles, saved views, a change log and full-text search. Issue rules:
  `KEY-n` identifiers that are never reused, lifecycle timestamps, fractional ordering, sub-issues, inverse
  relations, compare-and-set updates, team moves that keep the old identifier working.
- **Phase 2, MCP server (done).** `trackaro-mcp` exposes 25 tools, 3 resources and 3 prompts over stdio. Agents
  use names (`ENG-42`, `"In Progress"`, `"me"`), every change is recorded under the agent's name, and the app
  shows agent edits live.
- **Phase 3, core UI (done).** Sidebar (My issues, Agent activity, per-team Issues, Active, Backlog), a fast
  AppKit issue list grouped by state, a details panel with editable fields and an activity feed that marks agent
  changes, quick create, a `⌘K` command palette with issue search, type-to-filter pickers (`S` `P` `A` `L` `⇧E`),
  `g` chords, multi-select, undo and redo that never overwrite an agent's newer change, a `?` shortcuts sheet,
  `trackaro://` deep links, light and dark appearance, and an app icon.
- **Kanban board (done).** `⌘B` switches any view to a board: drag cards between and within columns, arrow
  keys to move around, `⇧←` `⇧→` to step status, and cards animate when an agent moves them.
- **Filters and saved views (done).** `F` filters any list by status, priority, assignee, label, project or team,
  `/` filters by text, `⇧F` clears. `⌘S` saves the page plus its filters as a view in the sidebar, and edits to a
  view stay unsaved until you save or discard them. Agents see views in `get_workspace`, read them with
  `search_issues` `view`, and create them with `save_view` (for example a "Ready for agent" board).
- **Agent pings (prototype).** When you change an issue, agents can hear about it: Claude Code channel push,
  Claude Code and Cursor hooks, or a live `trackaro-mcp watch` feed. See [docs/agent-pings.md](docs/agent-pings.md).

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

Options: `--channel` pushes your changes into Claude Code as they happen (see
[docs/agent-pings.md](docs/agent-pings.md)), `--read-only` hides every tool that writes, `--agent-name "Claude (backend)"` records changes under a
custom name, `--database PATH` (or `TRACKARO_DATABASE`) points at another database file.

Agents can hand you links such as `trackaro://issue/ENG-42`, which open the issue in the app.

The server opens the same database as the app, so agents can work whether or not the app is running, and the app
picks up their changes within a third of a second.

### Tools

| Area | Tools |
| --- | --- |
| Orientation | `get_workspace` |
| Issues | `search_issues`, `get_issues`, `create_issue`, `create_sub_issues`, `update_issue`, `move_issue`, `bulk_update_issues`, `archive_issue` |
| Conversation | `add_comment`, `list_comments`, `get_issue_history`, `set_relation`, `remove_relation`, `mark_duplicate` |
| Planning | `list_projects`, `create_project`, `create_milestone`, `list_cycles`, `create_cycle`, `cycle_progress` |
| Views | `save_view`, `delete_view` (views are listed by `get_workspace`) |
| Setup | `create_label`, `create_team` |

Resources: `trackaro://workspace`, `trackaro://cycles/active`, `trackaro://issue/{identifier}`.
Prompts: `standup`, `triage`, `plan_work`.

## Roadmap

1. Foundation (done)
2. MCP server (done)
3. Core UI (done)
4. Planning: board and filters with saved views (done); cycle and project pages next
5. Notes, local inbox and reminders, release signing
