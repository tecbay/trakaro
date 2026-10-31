# Data model and store (TrackaroCore)

## Opening the database

- `TrackaroStore.open(at:)` opens a GRDB `DatabasePool` in WAL mode with a busy timeout, then runs
  `Schema.migrator`. If the app and `trackaro-mcp` migrate at once, the loser's migration fails and the retry in
  `init` finds it applied.
- `TrackaroStore.inMemory(clock:)` backs every test. Tests pass a stepping clock (`Fixture` in
  `Tests/TrackaroCoreTests/Support/TestSupport.swift`) so timestamps are distinct and ordered.
- Location: `TrackaroStore.defaultURL()` is `~/Library/Application Support/Trackaro/trackaro.sqlite`. The app and
  the CLI both honour `TRACKARO_DATABASE`.
- Migrations live in `Database/Schema.swift`: `v1` (everything up to saved views), `v2-automations` and
  `v3-artifacts-and-restore`. Add a new `registerMigration` for any schema change; never edit a shipped one. Keep them
  additive, since an older `trackaro-mcp` may still be running on the upgraded file.
- `open(at:)` copies a database with pending migrations to `Backups/` first. If the copy fails, the upgrade does not run.

## Backup and restore

`Store/TrackaroStore+Backup.swift`. `backup(to:)` uses SQLite's backup API and leaves one plain file. `BackupFolder`
names, lists and prunes the copies beside the database (`daily` keeps 7, `before-upgrade` and `before-restore` keep 5,
`manual` is never pruned). `restore(from:safetyCopy:)` works on a private copy: it refuses a damaged file, another
SQLite file, or a backup with migrations this build does not know; migrates it; re-adds agent members so running
sessions can still write; records the `restorePoint`; saves the safety copy; then writes into the live database through
the backup API. Nothing swaps the file on disk.

## Tables

| Table | Record | Notes |
| --- | --- | --- |
| `member` | `Member` | `kind`: user, agent, system. One local user (`localUser()`); agents created by name (`agent(named:)`). |
| `team` | `Team` | `key` prefixes identifiers. `issueCounter` only grows. Keys are unique among active (unarchived) teams, ignoring case. |
| `workflowState` | `WorkflowState` | Per team. `category` (triage, backlog, unstarted, started, review, completed, canceled) drives behaviour; names are free. `DefaultWorkflow.states` seeds Triage, Backlog, Todo, In Progress, In Review, Done, Canceled, Duplicate. |
| `label` | `IssueLabel` | `teamId` nil means workspace-wide. |
| `issue` | `Issue` | See fields below. `seq` is an INTEGER PRIMARY KEY used as the FTS rowid. |
| `issueAlias` | `IssueAlias` | Old identifiers after a team move, so `ENG-4` still resolves. |
| `issueLabel` | `IssueLabelLink` | Many to many. |
| `issueRelation` | `IssueRelation` | blocks/blocked_by, related, duplicate_of/duplicated_by. Stored in both directions. |
| `comment` | `Comment` | Soft delete via `deletedAt`. |
| `issueActivity` | `IssueActivity` | One row per field change, `field` is `IssueField`, `fromValue`/`toValue` are JSON text. Feeds the inspector and the agent feed. |
| `project`, `milestone`, `cycle` | same names | Projects span teams; cycles belong to one team and are numbered per team. |
| `savedView` | `SavedView` | `filter` is `IssueFilter` JSON, `layout` list or board, `sortKey` orders the sidebar. Names unique ignoring case. |
| `automation`, `automationRun` | `Automation`, `AutomationRun` | Column rules and their runs (v2). Runs keep a log file path and status. |
| `artifact` | `ArtifactSummary`, `Artifact` | A project's file, in the database as a blob, up to 25 MB. Name unique per project ignoring case; saving the same name replaces it and bumps `version`. Soft delete via `deletedAt`. Kind comes from `mimeType`, which has no CHECK. |
| `restorePoint` | none | One row after a restore: the feed head at that moment. `feed(after:)` moves a cursor before it, or past the head, to this point, so restored history is never reported as new. |
| `changeLog` | `ChangeEntry` | Append-only, every write of every model. `seq` is the change cursor the app polls. |
| `issueSearch` | FTS5 | External content over `issue` (identifier, title, description), kept in sync by triggers. |

`Issue` fields: `id` (UUIDv7), `teamId`, `number`, `identifier`, `title`, `description` (Markdown), `stateId`,
`priority` (0 none, 1 urgent ... 4 low), `estimate`, `dueDate` (`CalendarDate`), `sortKey`, `parentId`,
`projectId`, `milestoneId`, `cycleId`, `assigneeId`, `creatorId`, `startedAt`, `completedAt`, `canceledAt`
(all set by `StateTimestamps.entering`, never by hand), `stateEnteredAt`, `createdAt`, `updatedAt`, `archivedAt`,
`version`.

## Writing

- Create: `createIssue(NewIssue, by:)`, `createTeam`, `createLabel`, `createProject`, `createMilestone`,
  `createCycle`, `createView`, `createAutomation`, `addComment`.
- Update an issue: `updateIssue(id, IssuePatch, expecting:, by:)`. In `IssuePatch` a nil property keeps the
  field, `FieldUpdate.set(x)` sets it, `.clear` empties it. `expecting` is compare-and-set; undo always passes it.
  Returns `IssueChange` with the stored issue and the `changed: [IssueField]` list.
- Move: `moveIssue(id, IssueMove, by:)` handles state, position (`after`/`before` neighbours, fractional
  `sortKey`), and team changes (new identifier, alias kept, state mapped by name or category).
- Labels: `addLabels`, `removeLabels`, `setLabels`. Relations: `setRelation`, `removeRelation`.
- Planning: `updateProject(id, ProjectPatch, by:)`, `completeCycle(id, by:)`, `nextCycle(after:)`.
- Views: `updateView(reference, name:filter:layout:by:)`, `deleteView`. A reference is an id or a name.
- Every write records a `changeLog` entry (`recordChange`) and, for issues, `issueActivity` (`recordActivity`)
  inside the same transaction. Writes take `by memberId`, and `requireMember` checks it.

## Reading

- `issue(reference)` accepts an id, an identifier in any case, or an alias. `issues`, `children`, `activity`,
  `comments`, `relations`, `isBlocked`, `labels(forIssue:)`, `labelIds(forIssues:)` (batched).
- `snapshot()` loads every small reference table at once (`WorkspaceSnapshot`: teams, states, labels, members,
  projects, milestones, cycles, saved views, each with a `...ById` dictionary). Presenters and the app use it to
  turn ids into names without a query per row.
- `queryIssues(IssueQuery)` is the one list query: `text` (FTS prefix match), `issueIds`, `teamIds`, `stateIds`,
  `stateCategories`, `assignee`/`project`/`cycle` as `ReferenceFilter` (`.none`, `.anyOf`, `.noneOrAnyOf`),
  `labelIds` (any of), `parentId`, `priorities`, `includeArchived`, `includeSubIssues`, `order` (manual, priority,
  updated, created, due, relevance), `limit` up to `maxPageSize` (10 000), `offset`. Returns `IssuePage` with
  `nextOffset`.
- `searchIssues(text, limit:)` for the palette. `recentChanges(by: .agent)` powers Agent activity.
- `latestChangeSeq()`, `changes(since:)`, `feedHead()`, `feed(after:...)` for change tracking.

## IssueFilter

`Store/IssueFilter.swift`. The filter bar's state, the saved view document, and what `search_issues` and
`save_view` build. Dimensions: `text`, `teamIds`, `stateIds`, `stateCategories`, `priorities`, `assigneeIds`,
`labelIds`, `projectIds`. Each is "any of"; dimensions AND together. `IssueFilter.unset` (`"none"`) in
`assigneeIds` or `projectIds` matches unset. `normalized` drops blanks and empty lists. `applied(to: IssueQuery)`
only narrows (intersects). `narrowed(by:)` merges two filters with the same result as applying both. `json` is
sorted-key JSON; `init(json:)` throws `TrackaroError.invalid`. There is no cycle or milestone dimension yet.

## Progress

`Store/TrackaroStore+Progress.swift`. `IssueProgress` counts issues per category and estimate points; `fraction` is
completed over non-canceled. `projectProgress(projectId:)` returns overall plus every milestone;
`projectsProgress()` and `cyclesProgress(teamId:)` compute all at once with one grouped query.
`cycleProgress(cycleId:)` (older, in `TrackaroStore+Query.swift`) returns `CycleProgress`; `.issueProgress` converts it.

## Feed and change log

- `changeLog` is the cheap global "something changed" signal and the history of every model.
- `feed(after: FeedCursor, memberKinds:, excludingMember:, limit:)` returns `FeedEvent`s (an activity row or a
  comment, with the issue as it is now and the member) in time order, plus the next cursor. Filtered-out events
  still advance the cursor. A state change's `toValue` is the new state id as a JSON string.

## Errors

`TrackaroError`: `notFound(entity:reference:)`, `noMatch(entity:reference:options:)` (lists valid choices for
agents), `invalid(field:message:)`, `conflict(message:candidates:)` (stale `expecting`, ambiguous names, duplicate
view names). Messages are written to be acted on by a person or an agent.
