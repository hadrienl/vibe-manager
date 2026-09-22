# 0007 — Creating a session

- Status: accepted
- Date: 2026-09-21
- Issue: [#7](https://github.com/hadrienl/vibe-manager/issues/7)

## Context

Everything a session needs already existed separately: a stored `WorkSession` (#2), providers
that know how to launch a CLI (#3, #5, #6) and a pseudo terminal to run it in (#4). What was
missing is the moment they meet — one form, one write, one process — and the promise attached to
it: **Cancel creates nothing**.

That promise is easy to state and easy to break. A form that saves as it goes, or that starts a
process to "check" something, has already broken it by the time the user presses Escape.

## Decisions

### A draft is a value, never half a session

`SessionDraft` lives in the domain beside `WorkSession`, and never becomes one by mutation.
`CreateSession` takes a whole draft and returns a whole session, or throws with the list of
reasons it cannot. No intermediate state reaches the store, so Cancel has nothing to undo:
there is no cleanup path to get wrong, and none to forget.

The draft is also what the preview renders. The badge in the sheet and the row in the sidebar
are the same `SessionBadge`, so what the user previews is what they get.

### Validation is a list of remedies, and it is complete

`SessionDraft.validate()` returns **every** problem, never the first one — a form that reveals
its problems one at a time makes the user press Create three times to learn three things.

Each `SessionDraftIssue` carries a sentence and a way out, the shape `TerminalError` and
`AgentLaunchError` already use, so a validation problem, a launch refusal and a terminal failure
render through one view. An agent that cannot run reuses its own `AgentDiagnostic` summary and
its `AgentRemediation` list rather than inventing a second vocabulary for the same facts.

Only a name and a usable folder are required. Everything else has a default.

### The launch plan is the validator

Asking a provider for a plan has no side effect — ADR 0005 and 0006 made that a property of
providers — so `CreateSession` builds one as part of validation. The prompt size limit, the
model check and the working directory are therefore enforced by the agent that will run, not by
a second copy of its rules in the form. The plan that was checked is the plan that is launched:
for Claude Code it already carries the `--session-id` the conversation will be named with.

### Availability is checked twice, on purpose

Once when the sheet opens, once when Create is pressed. Between the two, a CLI can be
uninstalled and a folder deleted. Without the second check the session would be written and then
fail to start, which is exactly the state the user cannot tell apart from a broken application.

Unusable agents stay listed, disabled, with their diagnostic and their remedy: an agent that
disappears from the list teaches nothing. An agent that is merely unauthenticated stays
launchable — it asks for credentials itself, in the terminal — with a warning rather than a
refusal.

### No model is a real answer

`SessionAgentConfiguration.modelID` becomes optional, and the store moves to schema v2 to say
so. Both catalogues are caches the CLI writes for itself and may simply not exist; a sentinel
such as `"default"` would eventually be handed to `--model` as if it named a model. A v1
document migrates by keeping its identifier, and an empty one — which v1 could not legitimately
hold — becomes "no model" rather than a model named nothing.

### The identity is derived before it is chosen

A nameless draft wears a grey placeholder: colour would claim a decision nobody made. As soon as
there is a name, the symbol and the accent are derived from it with a hash written out in the
source, not from `Hasher`, whose seed changes at every launch — an identity that moved between
two runs would be worse than no identity. The first explicit pick freezes it.

### One irreversible step, and a failure that keeps the session

The order is fixed: validate, build the plan, **save**, publish and select, then start the
terminal, then the agent observer, then flip the session to `active`.

The session is stored `closed` and only becomes `active` once a process is actually running, so
a session that never started is a session the user can retry, not a lie about a running agent.

A launch that fails does **not** delete the session. Cancel and failure must not have the same
effect: the prompt the user just wrote is worth more than the tidiness of the store, and the
recovery path is #10's Restart. The pane keeps the terminal's own error and its remedy.

### One pane per session, owned by the launcher

`SessionLauncher` keeps a `TerminalPaneModel` per `SessionID` and starts it itself;
`TerminalPaneView` gained an `autoStart` flag so showing a pane never starts a process. Without
it, switching to a finished session would silently launch a second agent, and #8 could not keep
each terminal's state and scroll across tab changes.

Relaunching a session that is already running is refused rather than queued: two presses of
Create, or a restore that overlaps a running session, must not fork two agents.

### The agent is started at the size it will be shown in

A terminal program reads its size once, at startup, and draws itself around it. Spawning at 80×24
and resizing a moment later leaves the agent's first screen — its banner, its prompt box — laid
out for a terminal that never existed, and no later `SIGWINCH` repaints what is already drawn.

So the surface is mounted before there is a process: its own layout is what tells the pane how
many columns and rows to start with. The wait is bounded to half a second — if nothing has
measured itself by then the spec's size is used, because a launch that hangs waiting for a view
would be worse than a launch that is merely narrow.

### The offered models follow the selected agent, without a scheduler in between

Reacting to a change of agent through a property observer meant a detached task, and a window
where the selected agent and the listed models disagreed. That window was not theoretical: the
test that covered it passed alone and failed in a full run. Picking an agent is now one call that
sets the agent, drops a model the new one does not offer, and loads the new list.

### Watching a launch without knowing which CLI it is

`AgentLaunchObserver` is the seam ADR 0006 promised. Claude Code stores the identifier its plan
already carries; Codex has to discover one, from its rollout files and from the terminal output.
Both differences stay inside `VibeAgents`, behind three methods, so the launcher forwards a plan
and a stream of output without knowing which of the two it is talking to.

## Out of scope

The three-column workspace (#8 — the sidebar here is the minimum the ticket needs), several
repositories and worktrees (#12 — one folder, stored as the first `RepositoryContext`), the live
Git context (#13, #14), notes (#16) and prompt templates (#17 — the prompt stays free text).
