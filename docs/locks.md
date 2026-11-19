# Shared-resource locks

When several Claude Code chats work in parallel, some resources can only be used by one chat at a time: a QA lane,
or a repository's merge step. Trackaro owns these locks:

- **Atomic.** Taking a lock is one SQLite write transaction. Every chat's `trackaro-mcp` and the app share one file,
  and SQLite lets only one of them write at a time, so two chats can never both take a free lock.
- **First come, first served.** Waiters are served in the order they asked, across resources, so a web QA run
  waiting for both device lanes is not starved by device runs that keep slipping past it.
- **Wake-up.** When a lock is handed over, the chat that gets it is told through the Trackaro channel.
- **Expiry.** A lock is freed when its holder sends no heartbeat within its time to live (15 minutes by default), or
  as soon as the `trackaro-mcp` process serving its chat has ended.

## Resources and conflicts

The upgrade seeds `qa-web`, `qa-ios`, `qa-android`, `merge mobicart-be`, `merge mobicart-supernative`,
`merge mobicart-shopify` and `merge wordpress-elementor`. `qa-web` conflicts with `qa-ios` and `qa-android` in both
directions; `qa-ios` and `qa-android` can be held together. Resources and conflicts are rows in the database
(`lockResource`, `lockConflict`). Add more on the Locks page with **Add lock…**, which also sets what the new lock
cannot be held with.

## Tools

Every tool acts for the calling chat unless `session_id` names another, so a chat never needs to know its own id.

| Tool | Arguments | Result |
| --- | --- | --- |
| `acquire_lock` | `resource`, `task`, `note?`, `session_title?`, `ttl_seconds?` (60 to 86400, default 900), `session_id?` | `{status: "granted", expires_in_seconds}` or `{status: "queued", position, held_by: [...]}`. Asking again returns the current state. |
| `release_lock` | `resource`, `result_note?`, `session_id?` | `{released, granted_to: [...]}`. Only the holder can release. |
| `heartbeat_lock` | `resource`, `session_id?` | `{resource, expires_in_seconds}`. Only the holder. |
| `lock_status` | `resource?` | Every lock, or one: holder (task, chat, note, held for, waited, last heartbeat, expires in), queue in order with how long each has waited, and conflicts. This chat's entries say `"you": true`. Read only. |
| `leave_queue` | `resource`, `session_id?` | `{left, granted_to}` |
| `release_all_for_session` | `session_id?` | `{released, left_queues, granted_to}` |

A resource name that matches nothing returns the valid names. Names ignore case.

## How a chat is identified

Claude Code starts one `trackaro-mcp` process per chat and passes the chat's session id in the
`CLAUDE_CODE_SESSION_ID` environment variable. The server uses that id as the chat's lock identity, and records its
own process id next to each lock it takes. Without the variable, each connection gets an id of its own.

Each lock change writes a `lockEvent` row. Rows that a chat should hear about carry a `targetSessionId`: the chat
that was just granted a lock from the queue (`lock_granted`), or the chat that lost one (`lock_expired`,
`lock_force_released`). Each server polls only the rows addressed to its own session id and pushes them into its
chat as a channel event, with `meta.kind`, `meta.resource` and `meta.issue`. No other chat sees them.

Every acquire, queue, grant, release and expiry also writes a comment on the task's issue, such as
`Lock qa-web granted to TASK-71 (chat Checkout QA).`, from a system member called Locks. The user's change feed
ignores system members, so these comments never trigger agent pings or automations.

## Releasing when a chat closes

A closed chat's server process ends, and the next sweep (every 5 seconds, from any running server or the app) frees
its locks and drops it from queues. To release at once, add a SessionEnd hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "/Applications/Trackaro.app/Contents/Helpers/trackaro-mcp release-session" }] }
    ]
  }
}
```

`release-session` reads `session_id` from the hook's JSON on stdin. `--session ID` names one explicitly.

## Limits

- **Wake-up needs channels.** Events reach a chat only when Claude Code listens to the Trackaro channel, which is a
  research preview (`claude --dangerously-load-development-channels server:trackaro`). Without it, a queued chat
  learns it holds the lock by calling `lock_status` or `acquire_lock` again.
- **A grant to a closed chat.** If a chat closes while waiting, it is dropped from the queue on the next sweep. If
  its process ends right after being granted a lock, the lock is freed on the next sweep and handed on; the event
  stays unread.
- **A chat that reconnects** gets a new server process. The server records the new process against the chat's locks
  at startup, so the locks are kept.
- **Session ids can change.** If Claude Code gives a chat a new session id without restarting its MCP servers, the
  SessionEnd hook's id will not match the locks, and they are freed by heartbeat expiry instead.
- **Older servers** (0.2.x) have no lock tools. Restart a chat to give it the new server.
- **Force release can't be undone,** because the next chat may already be using the resource.
