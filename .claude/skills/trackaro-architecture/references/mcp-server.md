# MCP server (TrackaroMCP and trackaro-mcp)

Official Swift SDK, pinned `exact: "0.12.1"` in `Package.swift` (negotiates protocol up to 2025-11-25). Stdio
only. One process per agent session, sharing the database with the app.

## Startup and identity

`TrackaroMCPServer.start(store:options:transport:)` registers tools, resources and prompts and returns the
`Server`. `Options`: `readOnly` (hides and refuses write tools), `agentName` (overrides the derived name),
`channel` (Claude Code channel push), `channelInterval` (default 700 ms).

On initialize, the `Session` actor turns the client's `clientInfo` into an agent member via
`TrackaroMCPServer.agentName(for:)` (`claude-code` becomes "Claude Code", `cursor` "Cursor"). Every write in the
session is recorded under that member. `ToolContext` carries `store`, `user` ("me") and `agent` ("self").
`Instructions.text(readOnly:channel:)` is the server instructions string; it tells agents to call
`get_workspace` first and how to report work.

## Tools (30)

`TrackaroMCPServer.allTools` is `WorkspaceTools.all + IssueTools.all + ConversationTools.all + PlanningTools.all
+ ViewTools.all + ArtifactTools.all`.

| Area | File | Tools |
| --- | --- | --- |
| Orientation and setup | `Tools/WorkspaceTools.swift` | `get_workspace` (teams and states, labels, projects, active cycles, members, saved views), `create_label`, `create_team` |
| Issues | `Tools/IssueTools.swift` | `search_issues` (filters plus `view`, `cycle`, `parent`, order, cursor paging), `get_issues`, `create_issue`, `create_sub_issues`, `update_issue`, `move_issue`, `bulk_update_issues`, `archive_issue` |
| Conversation | `Tools/ConversationTools.swift` | `add_comment`, `list_comments`, `get_issue_history`, `set_relation`, `remove_relation` (destructive), `mark_duplicate` |
| Planning | `Tools/PlanningTools.swift` | `list_projects` (with progress), `create_project`, `update_project`, `create_milestone`, `list_cycles`, `create_cycle`, `cycle_progress` |
| Views | `Tools/ViewTools.swift` | `save_view` (upsert by name), `delete_view` (destructive) |
| Artifacts | `Tools/ArtifactTools.swift` | `save_artifact` (upsert by name; `content` or `file_path`), `list_artifacts`, `get_artifact` (binary only with `as_base64`), `delete_artifact` (destructive) |

Read-only tools, pinned by `advertisesToolsWithAnnotationsAndStrictSchemas` in `ServerTests.swift`:
`get_workspace`, `search_issues`, `get_issues`, `list_comments`, `get_issue_history`, `list_projects`,
`list_cycles`, `cycle_progress`, `list_artifacts`, `get_artifact`. There is deliberately no automation tool, since a
rule runs a shell command, and no backup or restore tool, since a restore replaces everything.

Resources (`Resources.swift`): `trackaro://workspace`, `trackaro://cycles/active`, template
`trackaro://issue/{identifier}`. Prompts (`Prompts.swift`): `standup`, `triage`, `plan_work`.

## ToolKit (`ToolKit.swift`)

- `ToolDefinition(name:title:description:inputSchema:readOnly:destructive:run:)`. `run` is a synchronous
  `(ToolContext, Arguments) throws -> Value`. Annotations come from `readOnly` and `destructive`.
- `JSONSchema.object(properties, required:)` always sets `additionalProperties: false`; helpers `string` (with
  `oneOf`, `nullable`), `integer`, `boolean`, `array`. Unknown or mistyped arguments fail before `run`.
- `Arguments`: `string`, `requiredString`, `int`, `bool`, `strings`, `date` (YYYY-MM-DD to `CalendarDate`),
  `priority`, `has(key)`, `isNull(key)`. "Omitted keeps, null clears": check `has` then map nil to `.clear`
  (`IssueTools.nullable` does this for references).
- `ObjectBuilder` drops nil and empty values; `setIssues` adds `issues` and `count`. `Output.render` is minified
  JSON. Errors thrown from `run` become `isError` results with the error's description.

## Resolver and Presenter

- `Resolver(context)` loads a snapshot and turns names into ids: `team`, `state(_:in:)`, `stateIds(named:teams:)`
  (same name across teams), `labels`, `labelIds(named:)`, `member` ("me", "self", a name), `project` (name or
  slug), `milestone`, `cycle` ("active", a number, an id), `issue`. Misses throw `noMatch` listing the options.
- `Presenter(store:snapshot:)` turns records into compact JSON with names: `summaries` (one line per issue),
  full issue detail, `project(_:progress:)`, `cycle(_:now:)`, `progress`.
- `IssueTools.filterProperties` and `IssueTools.issueFilter(from:resolver:)` are shared by `search_issues` and
  `save_view`, so a saved view and a search take the same arguments.

## Agent pings

- `AgentFeed` (`AgentFeed.swift`) turns `store.feed` events into lines such as
  `ENG-5 “Title”: the user moved it from Todo to In Progress`, filtered to the user's changes by default.
  `render(_:as:)` produces the exact formats for Claude Code Stop (`decision: block`), UserPromptSubmit
  (`hookSpecificOutput.additionalContext`) and Cursor stop (`followup_message`) hooks.
- `ChannelTransport` wraps the transport: it adds `experimental["claude/channel"]` to the initialize result and
  sends `notifications/claude/channel` with `{content, meta}`. `startChannelPump` polls the feed and pushes,
  excluding the session's own agent. Claude Code only listens with
  `claude --dangerously-load-development-channels server:trackaro` (research preview).
- CLI (`Sources/trackaro-mcp/main.swift`): default server mode (`--database`, `--read-only`, `--agent-name`,
  `--channel`); `watch [--all] [--interval]` prints lines for the Monitor tool; `pending --state FILE --format
  text|claude-stop|claude-prompt|cursor-stop` for hooks (first run records the position and prints nothing).
- Full research and setup: `docs/agent-pings.md`.

## Testing

`Tests/TrackaroMCPTests/Support/Harness.swift` starts a real server and a real MCP `Client` over
`InMemoryTransport` with an in-memory store and team `ENG`. `harness.call(tool, args)` returns parsed JSON and
throws on `isError`; `harness.failure(tool, args)` expects an error and returns its text. `Value` helpers in
the harness: `strings`, `pluck(key)`. Every new tool gets a test here, including one failure that checks the
error teaches the valid options.
