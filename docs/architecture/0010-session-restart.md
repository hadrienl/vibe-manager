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

### One verb, three answers

The user presses **Restart**. Underneath, `SessionRestartMode` records which of three things that
turned out to be:

- `firstLaunch` — the session was created and never ran (`closedAt == nil`). Nothing to resume,
  nothing to summarise: it gets the launch it never had, initial prompt included. The command even
  calls itself **Start Session** there, because promising a *re*start on the first run is a false
  sentence.
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
restarting it. Changing agent or model is #15, and it is a decision, not a fallback.

### A stored identifier the CLI would refuse is a fallback, not a failure

Resuming is attempted with the identifier the session carries; if the provider answers
`missingResumeIdentifier` or `resumeUnsupported`, the restart falls through to a fresh start with
an explanation rather than failing. That is exactly what "this conversation cannot be resumed"
means, and the user is told which of the four reasons applied
(`SessionRestartExplanation`).

### The summary is data the session already had

`SessionContextBrief` is built from the name, the dates, the agent, the folders with their recorded
`GitSnapshot`, the notes and the initial prompt — quoted as history, not restated as an order. No
disk is read, no model is called, and the same session always yields the same text: a summary the
user cannot predict is one they cannot check, and they are shown it before it is sent, in an
editable field.

Every dated fact says when it was recorded. A three-day-old branch written in the present tense
would have the agent reason about a branch that may no longer exist.

It is bounded by `AgentPromptLimits.argumentByteLimit` (16 KiB), because both CLIs refuse a prompt
on the standard input — in a pseudo terminal, the standard input is the keyboard. Over the limit,
whole sections are dropped in a fixed order (initial prompt, then notes, then folders) and the text
says it was shortened; half a note reads like a whole one, and the agent has no way to tell that
the sentence it is acting on was cut. An edited summary goes through the same clamp, so the user
cannot type a brief the launch would refuse.

The terminal's scrollback is deliberately not in it: it lives in memory, may already have been
released, and a truncated transcript passed off as a report would be worse than no report.

### Three locks, at three levels

The window that matters is between the command and the first process — a detection plus a plan —
and neither the launcher nor the domain has anything to say inside it. So:

1. **Intent** — `AppModel.restartingSessionIDs` covers the whole round trip; the button, the menu
   item and the accessibility action are disabled for as long as it lasts.
2. **Execution** — `SessionLauncher.launch` already leaves alone a session whose pane is running,
   and the restart goes through it: there is no second road to a process.
3. **Truth** — `reopen` is legal only from `closed`, so a restart that got past the first two
   writes nothing rather than recording two openings for one closing.

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

### A ghost resume is offered a way out, not given one

`claude --resume <uuid>` whose transcript was deleted exits within seconds; no check is possible
beforehand without reading the CLI's own store. When a **native** restart ends in under
`AppModel.resumeProbation` (8 seconds) with a non-zero code, the workspace offers **Restart Without
Resuming** and does nothing else. Relaunching automatically would put an agent to work on a summary
nobody has read.

### Failures leave the session exactly as it was

The order is the one #7 set — plan, then process, then status — so everything that fails before the
process leaves the session `closed`, with its notes and, above all, its `resumeIdentifier` intact: a
session must not become unresumable by being restarted unsuccessfully. Each refusal carries a
sentence and a remedy, shown as a banner rather than a dialog, because the workspace behind it keeps
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
or model while restarting (#15), summarising the conversation with a model, persisting terminal
scrollback, and restarting several sessions at once. An archived session still has to be unarchived
first (#9), deliberately.
