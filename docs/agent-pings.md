# Pinging agents when you change an issue

When you move a card, change a status or comment in Trackaro, a coding agent can hear about it and react.
This page records what Claude Code and Cursor support (researched 2026-10-31), what Trackaro implements, and
how to set each route up.

## Short version

| Route | Agent | Wakes an idle session? | Status | Setup |
| --- | --- | --- | --- | --- |
| Channel push (`--channel`) | Claude Code | Yes | Claude Code research preview | Launch flag each session |
| Stop hook (`pending --format claude-stop`) | Claude Code | No, fires when Claude finishes a turn | Stable | One settings entry |
| Prompt hook (`pending --format claude-prompt`) | Claude Code | No, adds context to your next message | Stable | One settings entry |
| Monitor on `trackaro-mcp watch` | Claude Code | While the watch runs (30 min max, re-armed) | Stable tool; idle wake unverified | Ask Claude to start it |
| Stop hook (`pending --format cursor-stop`) | Cursor | No, fires when the agent finishes a turn | Hooks are beta | One `hooks.json` entry |

Every route reports only what the person using the app did. An agent never hears about its own changes or other
agents', which prevents agents from ping-ponging each other.

## What the agent receives

One line per change, from the same change log the app uses:

```
ENG-5 “Migrate settings to SQLite”: the user moved it from Todo to In Progress
ENG-5 “Migrate settings to SQLite”: the user commented: “Please pick this up”
```

## Claude Code

### 1. Channel push (true push, research preview)

A channel is an MCP server that pushes events into a running session; Claude takes a turn when one arrives,
even when idle. `trackaro-mcp --channel` declares the `claude/channel` capability and sends the user's changes as
`notifications/claude/channel`, batched per poll so a burst of edits costs one turn.

```
claude mcp add --scope user trackaro -- ~/.local/bin/trackaro-mcp --channel
claude --dangerously-load-development-channels server:trackaro
```

Requirements and limits, per the Claude Code docs:

- Research preview. Needs a claude.ai or Console API key login; not on Bedrock, Vertex or Foundry. Team and
  Enterprise organisations must enable channels (Settings, Claude Code, Channels).
- Custom servers need `--dangerously-load-development-channels server:<name>` on every interactive launch, and
  Claude Code asks for confirmation each time. Listing the server in `.mcp.json` is not enough. Ignored with `-p`.
- Claude Code does not register channel servers that negotiate protocol revision 2026-07-28. Trackaro's SDK
  negotiates at most 2025-11-25, so this does not apply today.

Verified here: the capability handshake and the pushed notification, over real stdio with a real change made in
the app. Not verified here: Claude Code waking on it, which needs an interactive session.

### 2. Hooks (stable, no flags)

Hooks cannot wake an idle session, but they make Claude notice your changes at the next natural point. Add to
`.claude/settings.json` in a project, or `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command",
      "command": "~/.local/bin/trackaro-mcp pending --state \"$CLAUDE_PROJECT_DIR/.claude/trackaro.cursor\" --format claude-stop" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command",
      "command": "~/.local/bin/trackaro-mcp pending --state \"$CLAUDE_PROJECT_DIR/.claude/trackaro.cursor\" --format claude-prompt" }] }]
  }
}
```

- **Stop:** when Claude is about to finish and you changed something meanwhile, the hook returns
  `{"decision":"block","reason":"…"}` and Claude carries on with your changes in hand. With nothing new it
  prints nothing and Claude stops normally. Claude's own changes are never reported, so this cannot loop.
- **UserPromptSubmit:** your next message arrives with the changes attached as context.
- Both hooks share one state file, so each change is reported once. The first run only records the current
  position, so turning the hook on does not replay history.

### 3. Monitor (stable tool, polling feed)

Ask Claude: "Start a Monitor on `~/.local/bin/trackaro-mcp watch` and react to each line." Claude receives
each line as it is printed. Watches last 5 minutes by default and 30 at most, then Claude re-arms them. The docs
say Claude "interjects" on new output but do not state that an idle session wakes; untested.

### Not usable for this

- Standard MCP notifications (`resources/updated`, `notifications/message`) are not documented as reaching the
  model. `list_changed` only refreshes lists.
- `claude -p --resume <id>` cannot deliver into a session that is running in the background from a script.
- A long-polling MCP tool works (stdio tools time out after about 28 hours) but costs a turn per wake and moves to
  a background task after 2 minutes. Monitor does the same job better.

## Cursor

Cursor ignores server-initiated MCP notifications (`list_changed` is not supported per Cursor staff; nothing reads
`resources/updated` or logging), and there is no API to message an idle IDE chat. Prompt deeplinks pre-fill the
chat but never run it.

### Stop hook (beta)

`~/.cursor/hooks.json` or `<project>/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "stop": [{ "command": "~/.local/bin/trackaro-mcp pending --state ~/.cursor/trackaro.cursor --format cursor-stop", "loop_limit": 5 }]
  }
}
```

When the agent finishes and you changed something, the hook returns `{"followup_message": "…"}` and Cursor
submits it as the next message. With nothing new it returns `{}`.

### Headless (future)

The `agent` CLI can resume a chat by id: `agent -p --resume <chatId> "ENG-42 moved to Review"`. Trackaro could
run this when an issue enters a chosen column. It runs a separate CLI session, not the visible IDE chat.

## Next steps worth building

1. **Column automations:** "when an issue enters Ready for agent, run `claude -p` (or Cursor's `agent -p`) in
   this repository with this prompt." Fully documented on both sides and works with no session open.
2. **A "Watch" toggle per agent session in the app,** so you can see which sessions are listening.
3. **Confirm idle wake** for channels and Monitor in a real Claude Code session, then make channels the default.

## Sources

Claude Code: code.claude.com/docs/en/channels, channels-reference, hooks, hooks-guide, mcp, headless, sessions,
tools-reference, scheduled-tasks, cross-session-messaging, cli-reference.
Cursor: cursor.com/docs/context/mcp, cursor.com/docs/agent/hooks, cursor.com/changelog/1-7,
cursor.com/docs/cli/headless, cursor.com/docs/cli/reference/parameters, cursor.com/docs/cloud-agent/api/endpoints,
cursor.com/docs/integrations/deeplinks, and Cursor forum threads 147888, 151758, 161459, 135549.
