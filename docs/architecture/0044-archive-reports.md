# 0044 — Archive reports: batches and what they did

- Status: accepted
- Date: 2026-10-26
- Issue: [#408](https://github.com/hadrienl/vibe-manager/issues/408)
- Builds on: [0043](0043-automatic-archive-rules.md), whose runs form the batches;
  [0023](0023-session-journal.md), whose sentences and resources the reports read

## Context

Since #405, rules archive sessions on their own, and a session archived leaves the view. What it
did is written already — the journal's sentences and resources (#36), its dates (#406), its
running time and tokens (#18) — but reading it back means opening the archive, then each session.
#408 keeps, for each archive, a report of what was done: read the morning after, project by
project, without reopening anything.

## Decisions

### The batch

Each run of a rule that archives at least one session forms a batch: its date, its rule (named as
it was then), the sessions archived, and those it left with the reason — something running,
unarchived since it was done, over the rule's limit. A run on trial that would have archived forms
a batch too, marked trial, shown only when asked.

Archives by hand — ⌃⌘A, the swipe, the batch — join **one batch per day**, “Archived by Hand”: a
report of what was done does not depend on how it was archived, and ⌃⌘A pressed ten times does not
make ten batches. ⌘Z does not take a rule's archive back (0043), so no batch is ever “undone”; a
session unarchived since stays in its batch, and the report says when it left the archive, read
from its status history.

A batch keeps a **photo** of each session, taken right before it is archived: name, badge, group,
agent, dates (created, first In Progress, last arrived in Done), running time and tokens, the
journal's entries and resources. The report stays right after a rename, an unarchive, or a journal
cleared.

### The report

`ArchiveReport` is built from the batches alone, without an agent: project by project the sessions,
each with its dates, running time, sentences and the resources it created or changed, then the
totals — sessions, pull requests created, tickets touched, branches, running time. A period
(today, yesterday, the last 7 days, this month, chosen dates) gathers its batches, trials aside; a
session archived twice in it is reported once, as it stood the last time; sentences written before
the period are folded under “and N older entries”.

`ArchiveReportText` puts it in the user's language and in Markdown: a heading per project, a line
per session, the links of its resources (`http` and `https` only). What a session or an agent wrote
is escaped: a session's name never makes a heading or a link.

### The agent's paragraph

As the journal's summary: one pass of the first available agent that answers to a schema (Claude
Code `haiku`, no tools; Codex read-only, no network), outside any session, from an empty folder. It
is given the sessions' names, groups, journal sentences and resources, **16 KiB at most, never a
transcript**, and answers `{"summary": "…"}`, read strictly. It is written after a rule's batch, in
the background; a failure keeps the summary without agent and offers Try Again. Archives by hand
and periods are summarized on demand. It is on by default when the journal summarizes, which costs
the same kind of pass, until the user chooses in Settings › Automatic Archive.

### Storage

One file per batch, `Automation/Reports/<day>-<id>.json`, written as the journal is: a temporary
file in the same folder, synchronized, moved over, `0600` in a `0700` folder — it holds sessions'
names and sentences a model wrote. Batches are kept twelve months, removed when the reports are
read past that, and cleared from the Settings. A file that does not read is left where it is.
Diagnostics `archive.reports.*` hold counts, durations and outcomes, never a name or a text.

### Where it shows

Window ▸ Archive Reports, beside Usage: the periods, then the batches by day; on the right the
report, with Copy and Export as Markdown, Open and Unarchive for each session still archived. The
notification of a rule's batch opens its report; the archive's list has See Reports; the Settings
have the paragraph's switch, Show Reports and Clear Reports….

## Consequences

- An archive is no longer the end of what the application says about a session: its report outlives
  it for a year.
- Showing yesterday's report at the first launch of the day is left for later: the notification and
  the Window menu do it for now.
