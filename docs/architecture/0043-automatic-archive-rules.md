# 0043 — Automatic archive rules, described in a sentence

- Status: accepted
- Date: 2026-10-22
- Issues: [#405](https://github.com/hadrienl/vibe-manager/issues/405), and the domain part of
  [#406](https://github.com/hadrienl/vibe-manager/issues/406)
- Amends: [0009](0009-session-history-and-archive.md), where nothing left the list on its own;
  [0002](0002-session-persistence.md), whose store goes to schema 11

## Context

Archiving was always a gesture: ⌃⌘A, the swipe from Done, the batch. With dozens of sessions a
week, Done grows without end. #405 lets the user describe, in one sentence, precise rules that
archive finished sessions — “archive the red ones on the 15th, the green ones at the end of the
week” — which one of the agents already on the Mac translates, and which the application alone
reads, explains, previews, tries on made-up sessions over time, and runs at the time they say.

It needs a date the store did not keep: when a session arrived in Done, and whether the user took
it out of the archive since. That is #406's history of statuses, whose domain part is here.

Five principles decide most of what follows:

1. **The agent translates, the application decides.** What the agent answers is data: decoded
   strictly, parsed, checked, never run (as ADR 0033's themes).
2. **A rule is explained, never shown.** The user sees what the application says of it, in their
   language; to change it, they describe it again.
3. **The language has no ambiguous word.** “End of the week”, “red” or “in the evening” are
   resolved by the agent into exact values, by documented defaults, or asked.
4. **What is asked is checked before it is turned on**, on made-up sessions chosen to trap it.
5. **Archiving stays reversible and stops no work.** A session where something runs is skipped;
   nothing is deleted; a session the user unarchived is not sent back.

## Decisions

### The history of statuses (#406)

`WorkSession.statusHistory` keeps every move: date, from, to and cause — created, user, launch,
coordinator, unarchive, undo, rule (its id and name then), reconstructed. It is written by
`setTaskStatus`, `archive` and `restore`, the only paths that change a status, each of which now
takes its cause; the use cases give it (`ChangeTaskStatus`, `beginWork`, `ArchiveSession`,
`RestoreSession`, the coordinator, ⌘Z). At most 500 entries, the creation kept.

`sessions.json` goes to schema 11: v10 with one optional field, read entry by entry. A v10 session
is given a history rebuilt from its dates (To Do at creation, In Progress at its first start, then
where it stands), every entry marked `reconstructed`. A history that does not lead to the session's
status — a cause written by a later build, a chain broken by hand — is rebuilt rather than refused:
it never keeps a session from being read.

The section Suivi of the inspector that shows it waits for its mock-up (#406).

### The language

A rule says which sessions (`archive done sessions where …`), when (`on daily | weekdays | weekly |
monthly | every | continuously …`) and its options (`limit N`, `no catch-up`); `protect where …`
holds for every rule. The fields, their comparisons, values and meaning are one table in the code
(`ArchiveField`); the parser, the reference (`docs/archive-rules.md`) and the agent's instructions
come from it, and a test keeps the reference equal to `ArchiveRuleGrammar.document`. The printer
writes one canonical text that reads back as the same tree: it is what is stored and what is sent
back to refine.

Conditions are evaluated in three values: a fact the application does not know — the state of a Git
folder it could not read — matches nothing, and protects. `badge.color` compares the colour the
badge shows: a badge showing the project's icon has none.

### When rules run

`ArchiveSchedule.nextOccurrence(after:calendar:activatedAt:)` is a pure value on the Mac's calendar
and time zone: a time the clocks skip is the first that exists, a repeated one runs once, a day the
month lacks is its last day. `ArchiveRuleScheduler.decision` says, from a rule's last handled time,
whether it runs now, catches up (once, standing for the last time missed) or passes (`no catch-up`).

The rules live in `Automation/archive-rules.json`, changed under a lock every copy of the
application shares: a time due is **claimed** — `lastHandled` written — before it runs, so that two
copies never run it twice. A file this version cannot read is never written over and nothing runs;
a rule that no longer reads is paused and says so. A protection that no longer reads keeps every
rule from running.

The application looks at the rules at the next time due (a quarter of an hour at most later), when
the Mac wakes, at launch once the running agents are adopted, and — for `continuously` — at each
change of the store, at most once a minute.

### A run

Each session the plan names is archived through `ArchiveSession` — detach, then write, as by hand —
with the cause `rule`; the run is one entry of `SessionSidebarHistory`, so ⌘Z takes it back while
the application runs. A run on trial archives nothing and records what it would have. The result is
shown on the rule's line; a discreet notification, which can be turned off, says it. Diagnostics
`archive.rules.run` and `archive.rules.generation` hold counts and durations, never a sentence, a
rule or a session's name.

### Asking an agent

As the themes and the sounds: a pass of Claude Code (`sonnet`, no tools) or Codex (read-only
sandbox, no network) outside any session, from an empty folder. The agent is told the grammar, the
defaults, the date and time zone, the language, the palette, the symbols, the groups' names and the
agents — nothing that comes from a session. It answers `{rules, question, assumptions}`, held to
`docs/schemas/archive-rule-answer.schema.json`; an answer that does not read is sent back once
with its problems; a question is shown with its choices; `assumptions` are what the agent chose
where the sentence left it open, shown under the explanation.

### The test bench

`ArchiveRuleBench` runs the rules over made-up sessions (`ArchiveBenchCases`: for each field read,
one that matches, one that just misses, one on the edge; and the traps: something running, a session
unarchived, a project icon, the other columns, done a minute before and after the time) with a
simulated clock and periods the Mac is off, through `ArchiveRuleScheduler.decision` and
`ArchiveRuleEvaluation.plan` — the code of the real runs, never copied; a test checks both give the
same dates. Everything is computed once per change; moving the cursor computes nothing.

## Consequences

- An archive is no longer always the user's gesture, but it is always one they described, saw
  explained, tried, and can undo.
- What is not done yet: the inspector's section Suivi (#406), the reports of the batches (#408),
  made-up sessions kept with the version they test (they live as long as the bench is open), and
  the cases proposed by an agent, which the ticket left to decide.
