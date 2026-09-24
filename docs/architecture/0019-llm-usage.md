# 0019 — Tracking what the agents use

- Status: accepted
- Date: 2026-09-24
- Issue: [#18](https://github.com/hadrienl/vibe-manager/issues/18)

## Context

A user running several agents wants an idea of what each session consumed: how long its agent ran,
how often it was started or resumed, with which model, and how many tokens it spent. The figures are
indicative, not a bill, and three constraints frame them: nothing leaves the Mac, what the agents
were asked or answered is never read, and the user can turn tracking off and erase it.

What the CLIs expose was measured before anything was designed (`claude` 2.1.281, `codex-cli`
0.156.1, keys only):

- Claude Code writes `message.usage` on each answer (`input_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`, `output_tokens`) and the model that answered in `message.model`. An
  answer with several blocks is written over several lines that repeat the same usage — 46 answers
  out of 55 in one transcript.
- Codex writes a `token_usage_record` per response, named by `response_id`, and the model in each
  `turn_context`. Older rollouts only have per-turn `token_count` events.
- Claude Code's `cost-state` lines carry a `totalCostUSD`, but it is not a counter: within one
  `startTime` it goes down as well as up (519 then 494), and `startTime` itself goes backwards.
  Codex reports no cost. Codex's cumulative `total_token_usage` drifts from the sum of its
  responses after a compaction (12.58 M against 12.81 M).

## Decisions

### Three kinds of figure, never confused

- **Measured** by the application: running time and runs.
- **Reported** by a CLI: tokens and responses, shown with `≈` and their source.
- **Unavailable**: said with its reason — not reported by this agent, no transcript, tracking off,
  not reliable — and never shown as zero.

### No cost

Neither CLI reports one that holds together, and computing one would mean shipping a price list that
is wrong within weeks (ADR 0005 and 0006 already refuse hard coded model lists for that reason) and
means nothing on a subscription. The cost is shown as unavailable, with that sentence.

### Running time is the life of the process, sleep excluded

`SessionLauncher` is the one road to a process, so it is where runs are recorded: `start` once a
process exists and the session was reopened, `end` from the exit watch (`exited`) or from `detach`
(`stopped`), `detach` from `handOff` when the terminal host keeps the agent (ADR 0017). Each start
says what it was — `start`, `resume`, `restartWithSummary`, `restartFresh` — and whether it came from
the restoration after a relaunch (`attemptRestart`) or from a switch (`launchSwitch`). The model is
the one the session asks for; `nil` is the CLI's default.

The start is written before the exit is watched: a process that ends at once — a resume the CLI
refuses — would otherwise see its exit handled first, and leave a run nothing closes.

Sleep is not running time: `NSWorkspace` sleep and wake notifications write `suspend` and `resume`,
and a `resume` always follows a written `suspend`, even when every run ended in between. A sleep
whose wake never came — the battery died, the application died asleep — is dropped at the next
`start` or `suspend` rather than stretched to the next wake, which would erase the runs between.
Time spent waiting for the user is running time: telling the two apart needs the agent state of #45.

### The journal is appended to, one file a month

`Usage/runs-YYYY-MM.jsonl`, one event per line, opened with `O_APPEND`, synchronized after each line.
A line costs the same whatever the history, and a month holds a few kilobytes. A last line cut short
by a crash is ignored. `UsageRecorder` is the only writer, so a session has at most one open run.

### A heartbeat bounds what a crash loses

`Usage/heartbeat.json` names the open runs and is rewritten every minute while one exists. At the
next launch, a run the journal never saw end is closed at the last heartbeat that names it, or at its
own start: a crash loses at most a minute. Reading the journal writes nothing; closing those runs is
`settleLaunch`, called once the launch has settled the terminal host, and never by a copy of the
application that found another one working in the same data (ADR 0011): that copy's recorder is
sealed, like its runtime recorder, and writes nothing at all. A line per minute in the journal would have cost ~20 MB a
year for a value only the last one matters for.

### Runs the terminal host kept

A run handed off at quit stays open (`detach`). Once the next launch has adopted what the host still
runs, it is settled: a session running again kept its run, which ran all along, and an `attach` says
so in the journal, so that a crash afterwards closes it at a heartbeat rather than at the hand-off; any other ended while the
application was away and is closed when the detection closed its session, never before the hand-off
and never after now. Whether the Mac slept meanwhile cannot be known, so that time counts.

### Tokens are read from the transcripts, and only their counters are kept

`AgentUsageReader` reads the files `AgentTranscriptLocator` finds — the same locator the activity
reader of #13 now uses — incrementally, from where the last reading stopped, whole lines only. A file
that shrank or changed inode is read again from the start.

What was said is never read. A line is decoded only when its bytes hold `"usage":` (Claude Code) or
`"token_usage_record"`, `"turn_context"`, `"token_count"` (Codex): in JSON a quote inside a string is
always escaped, so these can only match a key, never text typed by the user. It is then decoded into
types that declare nothing but counters, identifiers, a model and a date, the recipe of
`ClaudeCodeAuthenticationStatus` (ADR 0006); a test holds their field list.

Answers are counted once — Claude Code by `message.id` and `requestId`, Codex by `response_id` — with
the last 64 identifiers kept per file, since repeats are consecutive. Claude Code's `<synthetic>`
lines are skipped. Codex counts cached input inside its input, Claude Code beside it: both are
reported the way Claude Code does. A Codex rollout counts its records, or its per-turn events when it
has no record — skipping an event that repeats the previous running total, which an older Codex
writes when only its rate limits changed (198 of 863 events in the rollouts measured).

Totals are kept by file — keyed by a SHA-256 of its path, since a Claude Code project folder is
named after the repository — local day and model in `Usage/tokens.json`, because the transcripts belong
to the CLIs and they delete them (Claude Code after 30 days by default): a deleted transcript keeps
what it reported, and says so.

Transcripts are read only while a session's usage or the Usage window is on screen — the session
shown, or every session for the window — every thirty seconds, off the main thread. A reading that
a clear or the tracking switch overtook is dropped rather than saved.

### Off means nothing is counted, and cleared means nothing comes back

`Usage/tracking.json` holds the intervals tracking was on; without it, tracking is on and always
was, so the transcripts of existing sessions are counted from the first launch. Turning it off
closes what runs, stops writing and reading, and any token dated outside an interval is ignored when
a transcript is read later. **Clear Usage Data…** deletes the journal, the heartbeat and the token
totals, and starts a new interval now: reading the transcripts again brings nothing back from before
it. The agents' transcripts are never touched.

### Where it shows

- The Session pane of the inspector: a Usage section inside "Agent, usage & initial prompt".
- Window › Usage (⌥⌘U): a period (today, 7 days, 30 days, this month, previous month, all time), a
  grouping by session, agent or model, a daily chart, and a table. By model, time goes to the
  configured model and tokens to the declared one, and the column headers say so.
- Settings › General › Usage: **Track agent usage** and **Clear Usage Data…**.

## Consequences

- `AgentCapabilities.reportsUsage` is now true for Claude Code and Codex, false for the mock agent
  and any unknown provider.
- Running time and runs start with the version that ships this ADR; tokens go back as far as the
  transcripts that still exist.
- Sessions started outside Vibe Manager are never counted, even when their transcripts are on disk.
- The files hold session identifiers, provider and model slugs, dates and counters, the response
  identifiers used to count answers once, and digests of the transcript paths. No prompt, output,
  path or session name.
- A sleep during which the application was closed and the host kept an agent cannot be seen, and
  counts as running time.
- A CLI that changes the shape of its usage lines makes its tokens read as missing, not wrong.

## Rejected alternatives

- Claude Code's `cost-state` and Codex's `total_token_usage`: neither is a counter that survives a
  resume or a compaction.
- A price list, shipped or typed by the user: stale, and meaningless on a subscription.
- One document rewritten at each event: it grows with every launch.
- Reading the terminal output: it is the content the ticket forbids analysing, and its layout is not
  a contract.
- Reading `~/.claude.json`'s `lastCost`: it describes only the last session of a folder and sits next
  to data the application has no business reading.
