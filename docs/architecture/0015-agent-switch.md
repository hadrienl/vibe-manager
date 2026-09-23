# 0015 — Switching the agent or model of a session

- Status: accepted
- Date: 2026-09-23
- Issue: [#15](https://github.com/hadrienl/vibe-manager/issues/15)

## Context

#10 made a session restartable from what the store knows about it, and refused, on purpose, to
put it back to work on an agent the user had not chosen: "changing agent or model is #15, and it is
a decision, not a fallback". This is that decision.

Three facts of the code shaped it. The store kept only the current agent, so nothing could say
who had worked in a session. The transcript — which #12 and #13 read to know where the agent
worked and which files it wrote — was found through the current resume identifier only, so
replacing the agent would have made the previous one's work vanish from the inspector. And a
running agent can only be told apart from a stopped one, not a busy one from an idle one (#45).

## Decisions

### Two switches, not one

| Switch | What runs | Conversation |
|---|---|---|
| Same agent, another model, with a conversation to resume | `--resume <id>` with the new `--model` (`codex resume -m`) | goes on; no text is sent |
| Same agent without an identifier, or another agent | a new process, handed a summary | not transferred, and said so |
| A session that never ran | its first launch, initial prompt included | none existed |

Going back to an agent the session had before is a handover like any other. Its old conversation
knows nothing of what the other agent did since, and resuming it silently would have it work from a
stale picture; its identifier is kept for a later ticket to offer that deliberately.

### Everything that can refuse, refuses before the agent is stopped

`PlanAgentSwitch` is `RestartSession`'s twin with a target that is chosen rather than read back. It
accepts a running session, stops nothing and writes nothing: the target's availability, the model
against a catalogue that exists, the folder, the size of the summary and the launch plan itself are
all settled while the current agent is still working. A Codex that is not signed in must not cost
the user the Claude Code session it was meant to replace.

The current agent being unusable is not a refusal. It is precisely when another one is wanted, so
the command stays offered, and #10's refusal banner offers it too.

### The order: plan, stop, re-read, record, launch

1. **Plan** again with the text the user confirmed.
2. **Stop** through `CloseSession`. A stop that cannot be confirmed abandons the switch before
   anything is written: two agents in the same files is the worst possible outcome.
3. **Re-read**: a session archived during the stop is handed to nobody (`sessionMoved`).
4. **Record** (`RecordAgentSwitch`): the configuration left goes into the history, the next one
   becomes current, in one `mutate`. It happens *before* the launch because the new launch's
   observer writes its resume identifier on `session.agent`: written on the previous agent's
   configuration, it would name a conversation that agent has never heard of.
5. **Launch** in the same pane, under a separator naming both agents.

A launch that fails before a process exists is undone by `RevertAgentSwitch`: the previous
configuration comes back whole, resume identifier included, and the entry is marked failed. The
session is closed and **Restart** resumes the previous agent's own conversation. An application
that dies between 4 and 5 leaves a closed session on the new agent with no identifier; Restart then
hands over, and the history says the switch happened — relaunchable, nothing lost, and nothing
replayed behind the user's back (ADR 0011).

A new process that starts and then stops within `resumeProbation`, untouched and not stopped on
purpose, is not a failed switch: it existed, and its own words — a model the account cannot run, a
CLI asking to sign in — are in the pane. The closed session's bar then offers **Switch Back to …**,
which opens the sheet on the previous agent: a switch like any other, confirmed.

The switch takes #10's lock (`restartingSessionIDs`) for its whole round trip, and the open sheet
withholds Restart as a pending restart does. The rename to a lock named after launching, planned in
the ticket, was left out: the name is wrong by one verb, and renaming it touched every restart test
for nothing a reader could not infer from this line.

### A late identifier is never written on the wrong agent

`RecordAgentResumeIdentifier` is now built with the provider whose launch revealed the identifier,
and answers `agentChanged` — not retryable — when the session's agent is no longer that one. The
launcher already finishes the observer on `detach`; the check closes the window left. The observer
itself is chosen from the plan's provider rather than the stored agent, the one fact that cannot lag
behind a switch.

### The summary says where the work is

`SessionContextBriefBuilder.handover` is pure like the restart brief. Its input widens to what the
window already knows: the branch report (#12) and the Git states (#13) of the session. Nothing is
read for it, so the sheet never waits on Git; without them it falls back to the recorded snapshots
and says so.

The application defines no Git convention (ADR 0012), so the "conventions" the new agent is owed
are *where* the previous one worked: each repository, the branch checked out, whether it was
created or moved in this session, the worktree, what is left uncommitted, an operation in progress.
The one normative sentence is the last: continue on those branches and in those worktrees, and do
not create new ones unless asked. An agent that ignores where the work is makes a second branch,
and the work ends up cut in two.

The prompt the session was created with is never dropped: the ticket says the new agent receives
it, and it already fitted when the session was created. Shortening gives up, whole and in this
order, the older agents, the notes, the repositories only looked in, then the details of each
repository. Past that the summary is not cut: the sheet says by how many bytes it is over, and the
switch waits for the user to shorten it.

A restart brief of a switched session names the previous agents on its `Agent:` line, and nothing
else of it changed.

### The history is data the session keeps, not text it sent

`WorkSession.agentHistory` is a list of `AgentChange`: the date, the whole previous and next
configurations, what was handed over (the conversation, a summary with its size and whether it was
edited, the initial prompt, or nothing), and the outcome. The summary's text is not stored — it can
be rebuilt, and the store keeps no text sent to an agent (ADR 0002). A switch writes `agent` and
`agentHistory` and nothing else: the notes, the name, the appearance, the repositories and the
lifecycle are untouched, which the tests compare field by field. The lifecycle is `reopen`'s to
write, when the new agent actually runs.

`WorkSession.conversations` lists every configuration that was given an identifier, oldest first.
The transcript reader and the live Git monitor read and watch all of them, so the report of
branches and the attribution of changed files keep the previous agent's work.

### Schema v4

The store moves to v4, skipping the abandoned v3. A v2 document is read with an empty history and
rewritten, its original kept as the backup. A build that only knows v2 refuses a v4 document instead
of reading it, ignoring the history as an unknown key and erasing it at its first write: louder,
but nothing is lost, and the v2 backup is still there. The history is spelled out field by field in
the store, so a kind written by a later build is read as the closest one this build knows rather
than taking the whole store down.

### The sheet

One sheet, presented from the root like #10's. It opens on the current agent and model and offers
nothing until something changes. Unusable agents stay listed with their diagnostic and remedy,
through the `AgentOption` list the New Session sheet now shares. When an agent runs, the sheet says
it will be stopped and the button reads **Stop and Switch**. A continuity notice is always there,
worded for the case at hand. The summary regenerates when the target changes until the user edits
it, then keeps their words until they ask to regenerate. ⌘↩ confirms, because ↩ belongs to the
text.

The command is in the Session menu (⌃⌘M), the sidebar's context menu and accessibility actions, the
inspector's Agent section, and #10's refusal banner. The inspector lists the history, failed
switches included, each entry read in full by VoiceOver.

## Consequences

- `VibeDomain` and `VibeApplication` still know nothing of SwiftUI, AppKit or a process: the plan,
  the record, the revert and the summary are tested without a CLI, a disk or a window.
- There is still one road to a process: `SessionLauncher.start`, now also reached by
  `launchSwitch`.
- A fresh restart of the same agent still replaces its resume identifier without keeping the old
  one in the history, so its earlier transcript stops being read — a loss that predates this
  ticket. `conversations` is the shape that can fix it; changing #10's restart is its own ticket.

## Out of scope

Transferring the conversation itself, or summarising it with a model (#36). Resuming a conversation
an earlier agent had. Telling a busy agent from an idle one before warning about the stop (#45).
Changing a CLI's safety settings (ADR 0005, 0006). Switching several sessions at once, or the
default agent of new sessions. Usage per model (#18), which the history's periods will feed.
