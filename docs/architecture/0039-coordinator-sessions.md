# 0039 — Coordinator sessions

- Status: accepted
- Date: 2026-10-10
- Issue: [#352](https://github.com/hadrienl/vibe-manager/issues/352)

## Context

A user who hands an agent a set of tasks — "handle every ticket of milestone V2" — ends up running
the sessions by hand: one per ticket, each in its own worktree, started in the right order, watched
for the one that waits on a permission. #352 asks for a session that does that work: it creates
child sessions, chooses their agent, orders the work, and is the user's one point of contact.

## Decisions

### A coordinator is an ordinary session, plus a tool server

`WorkSession.coordination` (`SessionCoordination`) says whether a session coordinates others
(`.coordinator`) or is one of a coordinator's children (`.child(of:)`). Everything else is the same
session: the same terminal, conversation, sidebar row and commands. A child is a session the user
can open, write to, rename, close. There is no third level: the tools are given to coordinators
alone, and a child is never one.

`sessions.json` goes to schema 10, the v9 shape with one optional field, read field by field: a role
written by a later build, or a child said to be its own, reads as an ordinary session rather than as
a store that cannot be opened. A child whose coordinator is archived or gone is an ordinary session
again; the field is kept, so unarchiving the coordinator gives it back its children.

### The tools: a second server on the web view's channel

The coordinator's agent is given `vibe-sessions` beside `vibe-browser` (ADR 0023). The channel, the
bridge and the ancestry check are shared: the bridge is the same binary given
`--browser-bridge <socket> --server vibe-sessions`, and names its server in its hello
(`AgentToolServerDefinition`). A bridge that names none is the web view's, as every bridge was
before, so an agent left running in the terminal host keeps working. Each server lets in the
sessions it serves: the coordination server, the processes of coordinator sessions alone, whatever
the setting that gives agents the web view. With the application closed, the bridge still lists a
server's tools and says why a call fails.

| Tool | What it does |
|---|---|
| `agents_list` | The agents usable on this Mac, their models, and how many children run against the limit |
| `session_create` | A child, through `CreateSession` and the same publication as the sheet's, started or left in To Do |
| `sessions_list` | The caller's children: state, task status, request waited on, ticket, branch, pull requests |
| `session_read` | A child's state, its activity summary, and the last entries of its conversation, at most 12 000 characters |
| `session_send` | A message typed into a child as its composer would |
| `session_set_status` | todo, doing, waiting, done; moving a stopped child to doing starts it |
| `session_close` | Stops a child's agent |
| `wake_after` | Asks to be written to after 1 to 240 minutes; one wake-up at a time |
| `notify_user` | Marks the coordinator as calling the user, with a notification when the application is in the background |

A child of another coordinator, an ordinary session and an archived child are answered exactly as an
identifier that names nothing (`CoordinationPolicy`). Claude Code is started with
`--allowedTools mcp__vibe-sessions`, as for the web view: the application guards its own tools.

### The application creates nothing in Git

As ADR 0012 decided, the application makes no branch and no worktree. The coordinator creates the
child's worktree with its own tools and gives `session_create` the folder. What the application
does is refuse a folder another running session works in, compared once resolved, at creation and
when a stopped child is started.

### A permission is never answered by the coordinator

No tool answers a request. `session_send` is refused while the child waits for the user, or shows a
panel of its CLI: a key typed into a dialog could answer it. A child's request reaches the user
through the palette (#40) as any other, and the coordinator is told about it, to relay it. Answering
a child's clarifying question in the user's place was left out of this version.

### Woken by the application, without polling

An MCP call cannot wait for hours: Codex ends one after `tool_timeout_sec`, 60 s by default. The
coordinator ends its turn instead, and the application writes to it (`CoordinationInbox`) when a
child finishes a turn, waits for the user, stops, or is moved by the user, and when a wake-up it
asked for is due. Events are gathered for 3 s and typed as one message, marked `[Vibe Manager]`,
through the same encoding as the composer (`SessionLauncher.typeMessage`), queued as the agent
queues a message while it works. Nothing is typed while the coordinator waits for the user or shows
a panel; it waits. A coordinator whose agent is not running is told nothing: `sessions_list` says
the present state when it starts again. Wake-ups are kept in `Coordination/wakes.json`, so one due
while the application was closed is told at the next launch. A merged pull request is not something
the application sees: the coordinator asks to be woken, and checks with `gh` or `glab`.

### Who did what

A coordinator's message to a child, and the mission it creates it with, begin with
`[Coordinator “<name>”]`: they read so in the child's terminal and conversation. Each action —
created, messaged, moved, started, stopped — is kept in `Coordination/<child>.trace.json`, at most
200 entries, and shown in the child's inspector.

### The instructions

A coordinator is told what it is at every launch, on top of its agent's own system prompt:
`--append-system-prompt` for Claude Code, `-c developer_instructions=…` for Codex
(`AgentInstructing`), which replaces any the user's configuration holds, for that launch only. The
text (`CoordinatorInstructions`) asks for a plan the user approves once, a worktree per child, no
polling, no merge, and relays rather than answers. It is shipped with the application and not
editable: the user's wishes go in the session's prompt or a template.

### In the sidebar

`SessionHierarchy` lists each child right under its coordinator, in the coordinator's column and
group, whatever its own task status or folder; its own status is on its row. A search that finds a
child shows its coordinator. A coordinator folds its children (`WorkspaceLayout.collapsedCoordinators`)
and sums them up on its row: how many, how many run, how many wait for the user, or that it calls
the user. The children are rows of the same `List`, set in, not a nested disclosure: selection,
⌘-click and drags stay the list's (#96, #279).

The inspector gains a section, `coordination`: a coordinator's children, or a child's coordinator
and its trace.

### Limits

At most `CoordinationPreferences.maximumRunningChildren` children of one coordinator run at once, 3
by default, 1 to 10, in Settings › Coordination. Closing or archiving a coordinator with children
running asks whether they stop too.

## Consequences

- A coordinator spends no token while it waits; the cost of a wake-up is one turn.
- The coordinator relies on its agent's own forge tools; nothing in the application knows a forge.
- A process of the same user that writes into a coordinator's activity log can make it be told a
  false event (ADR 0022). What it is told is never acted on by the application: only the
  coordinator's agent reads it, as data.
- Left out, and possible later without undoing anything: a budget in tokens or time, an agent
  imposed or excluded in the settings, descriptions of what each agent is good at, archiving by the
  coordinator, answering clarifying questions in the user's place.
