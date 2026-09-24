# 0010 — Restarting a closed session

- Status: accepted
- Date: 2026-09-22
- Issue: [#10](https://github.com/hadrienl/vibe-manager/issues/10)

## Context

#9 made closing a session lossless: the process stops, everything else stays, and the pane keeps
the last thing the agent said. This ticket gives that state its way back to work.

The promise is small enough to write in one line and hard enough to be worth a record:
**restarting never creates a second session, and never loses the first one.** A session already
knows which agent ran it, with which model, in which folder, under which identity — restarting is
therefore not a form to fill in again but a plan to rebuild from what is stored.

## Decisions

### One verb, four answers

The user presses **Restart**. Underneath, `SessionRestartMode` records which of four things that
turned out to be:

- `firstLaunch` — the session was created and never ran (`startedAt == nil`). Nothing to resume,
  nothing to summarise: it gets the launch it never had, initial prompt included. The command even
  calls itself **Start Session** there, because promising a *re*start on the first run is a false
  sentence.

  The fact is recorded, not derived. A created session is stored *closed*, with its whole
  lifecycle sitting on its creation date, so `closedAt` cannot tell a session that never ran from
  one that was worked in and closed — keyed on `closedAt == nil` this mode was unreachable, and a
  session whose very first launch had failed was restarted with a summary apologising for a
  conversation that never existed. `SessionLifecycle.startedAt` is written by the first `reopen`
  and never overwritten; a store written before it existed has it inferred from the rest of the
  lifecycle, where only one shape — created, closed on the same instant, untouched since — means
  "never launched".
- `native(identifier:)` — the agent's own conversation is resumed, and **no prompt is sent**. The
  conversation already contains the instruction that started it; handing it back would set the
  agent off on a days-old brief a second time.
- `freshWithContext(_:)` / `freshWithoutContext` — a new process, with a summary of the session, or
  without one when the agent takes no initial prompt at all.

A fresh start is the only mode that sends anything, so it is the only one that asks first.

### The plan comes from the store, never from the screen

`RestartSession` is the twin of `CreateSession`: it validates, builds the plan that will be
launched, and starts nothing. The session is re-read from the repository at the moment of the
command, because a sidebar drawn a second ago may show as closed a session that has since been
reopened or archived. "The same agent, folder, worktree and appearance are reused" is then not an
intention the interface has to honour — it is what happens when nothing is re-chosen.

The folder is `repositories.first?.git?.worktreePath ?? repositories.first?.path`, checked by
`WorkingDirectoryProbe` before anything is launched. A worktree deleted between two sessions is
ordinary; finding out through a terminal that dies on `chdir` tells the user nothing they can act
on. Several repositories per session are #12, and until then the rule is stated rather than
discovered.

An unknown or unusable agent is a typed refusal, never a substitution: restarting someone's work in
an agent they did not choose, without their conversation, would be a worse outcome than not
restarting it. Changing agent or model is #15, and it is a decision, not a fallback. *(ADR 0015:
the refusal's banner now offers **Switch Agent…** beside **Detect Again**; Restart itself still
never substitutes an agent.)* The command is
withheld rather than offered and then refused, using the resolution the detections already left on
the model — no probe is run to draw a sidebar row, and a session whose agent has not been resolved
yet keeps its command, because "not asked yet" is not "unusable". When a refusal does reach the
banner, **Detect Again** is on it: most of these are a CLI the Mac cannot see right now, and that
is what turns it around without leaving the workspace.

### A stored identifier the CLI would refuse is a fallback, not a failure

Resuming is attempted with the identifier the session carries; if the provider answers
`missingResumeIdentifier` or `resumeUnsupported`, the restart falls through to a fresh start with
an explanation rather than failing. That is exactly what "this conversation cannot be resumed"
means, and the user is told which of the four reasons applied
(`SessionRestartExplanation`).

### The summary is data the session already had

`SessionContextBrief` is built from the name, the dates, the agent, the folders with their recorded
`GitSnapshot`, the notes and the initial prompt — quoted as history, not restated as an order. No
disk is read, no model is called, and the same session always yields the same text on a given Mac:
a summary the user cannot predict is one they cannot check, and they are shown it before it is
sent, in an editable field. Only the time zone follows the reader — "closed at 18:40" is about the
afternoon they remember, not about UTC — while the shape of every date is fixed.

Every dated fact says when it was recorded. A three-day-old branch written in the present tense
would have the agent reason about a branch that may no longer exist.

Clearing the field is a real answer — start it again, tell it nothing — so an emptied summary
becomes `freshWithoutContext` rather than a `freshWithContext` carrying nothing: the sheet and the
terminal's separator both claim a summary was handed over, and neither may say so falsely.

It is bounded by `AgentPromptLimits.argumentByteLimit` (16 KiB), because both CLIs refuse a prompt
on the standard input — in a pseudo terminal, the standard input is the keyboard. Over the limit,
whole sections are dropped in a fixed order (initial prompt, then notes, then folders) and the text
says it was shortened; half a note reads like a whole one, and the agent has no way to tell that
the sentence it is acting on was cut. An edited summary goes through the same clamp, so the user
cannot type a brief the launch would refuse.

VoiceOver is told which of the four modes the command will take — "Restart audit deps, resuming its
Claude Code conversation" — and it is told from the same two stored facts `RestartSession` decides
on, never by building a plan: an announcement that cost a detection would be one the sidebar could
not afford to make.

The terminal's scrollback is deliberately not in it: it lives in memory, may already have been
released, and a truncated transcript passed off as a report would be worse than no report.

### Three locks, at three levels

The window that matters is between the command and the first process — a detection plus a plan —
and neither the launcher nor the domain has anything to say inside it. So:

1. **Intent** — `AppModel.restartingSessionIDs` covers the round trip, and `pendingRestart` covers
   the wait for an answer. They are two states, not one: a summary on screen is not work in
   flight, and holding the work lock for the life of a sheet would have been a lie that eventually
   leaks. Both are consulted by `canRestart`, so the button, the menu item and the accessibility
   action are withheld in either case — without which ⌃⌘R re-asked the question and left the text
   the user had started editing attached to a plan nobody would send.
2. **Execution** — `SessionLauncher.launch` leaves alone a session whose pane is running. For that
   to be true, a pane must call itself `starting` from the moment `start` is entered, not once it
   has measured itself: it waits up to 500 ms for a layout pass, and for that whole window it used
   to still report the previous run's exit code. A second launch arriving there passed the guard,
   was dropped silently by the pane's own re-entrancy check, and then wired its exit watch to the
   dead terminal.
3. **Truth** — `reopen` is legal only from `closed`, so a restart that got past the first two
   writes nothing rather than recording two openings for one closing.

### Archiving and launching can cross, and only one of them may win

`restartingSessionIDs` does not stop the user from archiving, and a restart holds a value read
before a detection and a launch plan — seconds, on a cold cache. The store is therefore asked twice:
once before the process is spawned, and once when `reopen` comes back refused. A refusal means the
session moved while the launch was under way, and archived is the case that cannot be let through —
the pane is disposed and the process stopped, because "nothing stays attached to an archived
session" is worth nothing if a launch a moment too late can break it in silence.

One refusal is harmless and one only: the session is already `active`, because another path opened
it first. Everything else — a write that failed, a store that would not answer — is treated like
the archive: the pane is disposed and the process stopped. Letting those through left a live agent
attached to a session the store still called closed, and nothing reconciled it, because the exit's
own `close` was refused for the same reason and discarded.

### A separator that was never earned is thrown away

The notice is queued on the pane and consumed by the surface when it attaches to a terminal. A
launch that never reaches one therefore has to drop it: kept, it would be drawn above the *next*
process, announcing a restart that did not happen, at a time that is not that process's.

The separator line travels *with* the launch rather than being posted beforehand, and that is not a
detail: posting it meant creating the pane first, and a pane that exists but has never started
reads as `starting` — which is precisely the state `launch` refuses to start over. Pre-creating it
made every restart a silent no-op.

### A restart is announced in the terminal

The pane is reused, so the previous agent's output stays above the next one's — that is what
"keeps its context" looks like to the person watching. A dim, dated line is written between them
(`── Restart · 22 Sep 2026 at 14:03 · resumed conversation ──`), because two runs sharing one
buffer make yesterday's output read as today's. It names the mode, so a user who reads "new
process" knows the agent above has been told none of it.

### A ghost resume is remembered, and told at the next restart

`claude --resume <uuid>` whose transcript was deleted — or whose lock a killed process left behind
— exits within seconds; no check is possible beforehand without reading the CLI's own store. When a
**native** restart ends in under `AppModel.resumeProbation` (8 seconds) with a non-zero code, the
session is recorded in `resumeRefusals` and **nothing is shown**.

Nothing is relaunched either: putting an agent to work on a summary nobody has read would double
the work behind the user's back. But the news is not announced when it happens, because the person
watching has just finished with that session — a banner there interrupts them with something they
can do nothing useful with yet. It is acted on the next time they ask for that session: the restart
skips the resume, and the summary sheet they have to answer carries the reason
(`resumeFailedBefore`). That is the moment the fact matters, and the sheet is already the place
where a fresh start is read, edited or called off.

A restart that reaches a process clears the refusal: that process has a conversation of its own,
and a stale refusal would skip the resume of an identifier that has since been replaced. Nothing is
persisted either — a lock left behind by a killed CLI is usually gone by the next launch, and a
session refused today deserves one more honest try tomorrow.

Two endings are never a refused resume, whatever they exit with: one the user typed into
(`TerminalPaneModel.hasReceivedInput` — an agent that refused its conversation exits before a key
is pressed) and one this application killed itself (`wasStoppedOnPurpose` — that is Close
answering, not the agent refusing). Without them, closing a session within eight seconds of
restarting it announced that its conversation had been lost, which was simply untrue.

The window is measured against an injected `SessionClock`, which is the only reason its far side
can be tested at all: the rule "past the probation, it is an ordinary close" would otherwise cost
eight seconds of sleep per assertion.

What the process ended in travels *with* the closure — `sessionDidClose` carries the final
`TerminalProcessState` — rather than being read back from the pane. The pane is driven by its own
attachment, on its own task, with no ordering against the exit watcher: asked during that gap it
answered "still running" about a process that had already exited, the offer was skipped, and the
attempt was dropped by the probation check a moment later. Nothing is re-read, so there is no gap
left to lose it in.

### The sidebar follows the session it just put back to work

The two sidebar tabs split on whether an agent is running (#9), so a session restarted from
**Closed** leaves that tab the instant it starts. Left alone, the session the user had selected
vanished from the list under their pointer and the selection fell to whatever row took its place —
the one command whose whole point is "get back to this session" ended by showing them another one.

`AppModel.follow(_:)` therefore moves the scope to the tab the session is now in and re-selects it,
after the reload that published the new status. It runs after every restart, successful or not: a
restart that failed left the session closed, which this simply confirms. Creating a session does
the same, for the same reason.

Only the scope moves. A search or a facet that also hides the session is a narrowing the user typed
themselves, and clearing it would undo work they can see.

### One sheet, presented from the root

The restart confirmation is one of the three sheets in `presentedSheet`, not a `.sheet` of its own
on the workspace column. SwiftUI presents a single sheet per view and drops the rest, and the
column it was attached to only exists while the store is loaded: a refresh that failed while the
summary was open tore the sheet down with `pendingRestart` still set, leaving a restart nobody
could confirm or call off — and `canRestart` withheld for that session ever after.

### Failures leave the session exactly as it was

The order is the one #7 set — plan, then process, then status — so everything that fails before the
process leaves the session `closed`, with its notes and, above all, its `resumeIdentifier` intact: a
session must not become unresumable by being restarted unsuccessfully. A store that cannot be read is its own refusal, apart from "this session is gone": a failed read
establishes nothing about what the store holds. Each refusal carries a sentence and a remedy, shown as a banner rather than a dialog, because the workspace behind it keeps
working.

## Consequences

- `VibeDomain` and `VibeApplication` still know nothing of SwiftUI, AppKit or SwiftTerm: the modes,
  the refusals and the brief are plain `Sendable` values, and every one of their rules is tested
  without a CLI, a disk or a window.
- `sessions.json` is unchanged. Restarting writes `lifecycle` through `reopen`, and the new
  `resumeIdentifier` that a fresh Claude Code process assigns itself — an expected consequence of
  starting a second conversation, recorded here so it is not read as a bug.
- #11 (restoring sessions at launch) has the use case it needs: it can walk the store, ask
  `RestartSession` for a plan, and never have to know the rules again.

## Out of scope

Resuming automatically at launch (#11), several repositories and worktrees (#12), changing the agent
or model (#15, its own command — ADR 0015), summarising the conversation with a model, persisting terminal
scrollback, and restarting several sessions at once. An archived session still has to be unarchived
first (#9), deliberately.
