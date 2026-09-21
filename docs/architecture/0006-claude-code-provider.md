# 0006 — The Claude Code CLI provider

- Status: accepted
- Date: 2026-09-21
- Issue: [#6](https://github.com/hadrienl/vibe-manager/issues/6)

## Context

ADR 0005 added the first real agent and, with it, the doubt it was meant to settle: is a
provider really "a specification and an argument builder"? Claude Code answers it. Everything
common with Codex — detection, caching, diagnostics, the registry, the pseudo terminal — is
reused untouched, and the whole provider is four small types.

One property of this CLI changes the design instead of repeating it: **Claude Code accepts the
session identifier it is given**.

## Decisions

### The interactive interface, never `--print`

`-p/--print` answers and exits: no approvals, no way for the user to take over, no terminal
interface. The application drives the same `claude` a user runs by hand, in the pseudo terminal
ADR 0004 provides.

### The identifier is assigned, not discovered

Codex had to be watched — a rollout file, the terminal output, a race between two sources and
their false positives. Here Vibe Manager generates a UUID and passes `--session-id <uuid>`. The
conversation is named before it exists.

This removes a whole machinery: the identifier never has to be *found*, only confirmed.

`ClaudeCodeSessionIdentifierCapture` reads that identifier back out of the plan's arguments, so
the value written to the session is the one the process was actually started with, never a value
guessed in parallel. The identifier is a property of the *plan*: `launchPlan(for:)` can be called
for a preview without consequence, only the plan that is executed is recorded.

Being named is not the same as existing. A run that never reaches a first exchange — a process
that fails to start, a pane closed at the trust prompt — writes no transcript, and an identifier
stored for it would make the next launch ask the CLI to resume a conversation it has never heard
of. So, as for Codex, the write waits for evidence: `ClaudeCodeTranscriptWatcher` polls
`<config>/projects/**/<uuid>.jsonl` until the CLI has filed the conversation, and only then does
`RecordAgentResumeIdentifier` run. What Codex needs discovery for, this needs only confirmation
for — the file name is known in advance, so there is no matching, no race between sources, and no
false positive. A conversation that never appears leaves nothing behind.

Keeping it is a third thing again. The session row may not exist yet, or may
not carry its agent configuration, when a pane starts, so the write is retried inside a bounded
window and what it never managed to store is exposed as `unstoredIdentifier` rather than
dropped. The conversation exists on the user's disk either way; staying silent about it would
be the one outcome that loses it.

### A plan names one conversation, and only one

`--session-id` is refused by the CLI once that identifier exists in this directory — *Session ID
… is already in use*. Replaying a plan therefore starts nothing, which matters because #4 lets a
finished pane restart. A restart has to ask the provider for a plan again: with the identifier
the session now carries it produces `--resume`, and without one a new conversation. Nothing in
this ticket drives that path — the creation flow is #7 — so the rule is stated here rather than
enforced in a code path that does not exist yet.

### Resume names its session, and never forks

`claude --resume <uuid>`, with the identifier required. A bare `-r` opens an interactive picker
that would leave the pane waiting on a selection nobody is there to make, and `-c/--continue`
resumes "the most recent conversation in this directory" — possibly one started by another tool.
`--fork-session` is never passed: it would mint a new identifier and break the link the session
just stored.

`--session-id` and `--resume` are mutually exclusive — the CLI refuses the pair unless
`--fork-session` is also given — so the argument builder makes that combination unreachable
rather than documenting it.

A resume identifier must parse as a UUID. The CLI refuses everything else anyway; refusing it
before a process is started turns a screen full of red into a typed error.

### The prompt is an argument, behind `--`, never the standard input

In a pseudo terminal the standard input *is* the keyboard: writing a prompt there types it into
the composer and its first newline submits a half written message. `ClaudeCodeArgumentBuilder`
refuses a `.standardInput` delivery with `promptTooLarge`, and the plan only ever carries
`.argument` or `.none`.

The separator is not a precaution, it is required: `claude "-x prompt"` fails with *unknown
option*, `claude -- "-x prompt"` does not.

### The working directory is passed once, because there is only one

Codex takes `-C` in addition to the process directory. `claude` has no such option: the working
directory *is* the project. It decides what the CLI reads, and where the conversation is
written. Passing a path anywhere else would create a second source of truth, and one of the two
would be lying. Additional directories (`--add-dir`) belong to #12.

### Models come from the account, not from the source code

`models()` reads `<config>/cache/model-catalog/*.json`, which the CLI writes for the signed in
account — no network call, no process. Files written for the `cc` surface (the CLI's own) win
over `ccd` (the desktop application); without any `cc` file the freshest catalog of any surface
is used, because the identifiers speak the same vocabulary and something beats nothing.
`main` models are offered first, then `overflow`.

The file names are random hashes, so they order nothing: candidates are opened newest first, the
`-cc.json` suffix only deciding what is opened *first*, and only the decoded `surface` is
trusted. Reading stops at the first usable catalog, so the normal case costs one read whatever
the directory has accumulated, and a bound on the number of reads keeps a directory that has
gone wrong from becoming a directory scan.

Nothing is hard coded, not even the aliases the CLI accepts: a shipped list would show models
this account has no access to, and miss the ones released next month. The cache reflects what
*this* user may actually run. A machine where Claude Code has never run offers no model until it
has, which is honest rather than wrong.

The launch validation only checks that a slug is a plausible token. An empty choice means
"whatever the user's own settings say", which is their decision to make.

### Authentication is one boolean, and identity is never read

`claude auth status --json` answers without a network call. Its answer also carries the email
address, the organization and the subscription type: none of them is decoded.
`ClaudeCodeAuthenticationStatus` declares a struct with a single `loggedIn` field, so the rest
cannot reach a log, a diagnostic or an export even by accident.

This is the one place where ADR 0003's exit-code-only rule was not enough — the command exits
with `0` either way — so `CommandLineAgentSpecification` gained an optional
`authenticationOutcome` closure. Codex passes none and keeps the exit code.

An unproven sign in state stays launchable: the CLI asks for itself, in the terminal, where the
user can answer.

### Secrets are never touched, routing variables are forwarded

Neither `ANTHROPIC_API_KEY`, nor `ANTHROPIC_AUTH_TOKEN`, nor `CLAUDE_CODE_OAUTH_TOKEN` is read,
stored or injected, and `~/.claude/.credentials.json` and the keychain are never opened.
`claude auth login` owns that, and forwarding a key would silently decide which account is
billed.

`CLAUDE_CONFIG_DIR` is forwarded when set, and the same value decides where the model catalog is
read. A tilde prefixed value is expanded; one that cannot be resolved into an absolute path is
dropped instead of being passed on, so the CLI and the reader never disagree about where the
configuration lives. Proxy and certificate variables are forwarded too, because a corporate Mac
without them fails with a network error whose cause is nowhere near its message.

`CodexHome` and `ClaudeCodeHome` are now two thin facades over `AgentHomeDirectory`: the third
agent will not write this a third time.

### Nothing lowers the user's safety settings, nothing leaves this Mac

Never `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`,
`--permission-mode`, `--tools`, `--allowedTools`, `--disallowedTools`, `--settings`,
`--mcp-config`, `--plugin-*`, `--bare` or `--safe-mode`. The policy is the user's, and lowering a
guard rail from a graphical interface would be a silent privilege escalation. Exposing those
settings is product work (#7, #15).

Never `--bg`, `--cloud`, `--teleport`, `--remote-control`, `--worktree`, `--tmux`, `--ide` or
`--chrome` either: the session has to live in the pseudo terminal the application supervises,
displays and stops. Worktrees are #12.

### The minimum version is the one that was verified

Only `--session-id`, `--resume <uuid>`, `--model` and `auth status --json` are used, and they
were checked against `2.1.278 (Claude Code)`. The declared minimum is that series, `2.1.0`, not a
rounder number one version older: `auth status` is recent, and a CLI without it would answer the
probe with a usage error, which reads as "signed out" for good. The application states what it
verified rather than what it assumes.

## Consequences

- Adding Claude Code touched no view and no use case: a specification, an argument builder, a
  catalog, an identifier capture, one optional field on the shared specification, and one line in
  `AppEnvironment`.
- The identifier can no longer be missed on the launch side, which was ADR 0005's main residual
  risk. It can still fail to be stored, which the retry window narrows and `unstoredIdentifier`
  reports. A session that dies before its transcript exists now stores nothing at all, so a
  restart opens a new conversation instead of resuming one the CLI would refuse.
- The identifier is therefore not resumable *instantly*: between the launch and the first
  exchange the session carries none. That window belongs to a conversation that does not exist
  yet, so nothing is lost by it.
- Reading the catalog is still blocking file access inside an `async` function, now bounded to
  one read in the normal case. If a model picker ever reads it on every keystroke it wants a
  cache, not a smaller bound.
- Model choice depends on a file written by the CLI, so it depends on the CLI having run once.
- A large prompt is refused instead of being half delivered, and the limit is visible.
- Setting the conversation's display name (`-n/--name`) is left out: it would mean widening the
  shared `AgentLaunchRequest` for a single provider. #7 owns the session title and can decide.

## Rejected alternatives

- Discovering the identifier the way Codex does — reading it out of the transcript or the terminal
  output — was rejected: the CLI accepts being told, so observing it would be guessing an answer we
  already have. The transcript is still watched, but only to confirm the conversation exists.
- Storing the identifier at plan time and letting resume fail on its own — the CLI does say *No
  conversation found with session ID: …* — was rejected: it puts a value the app knows to be
  doubtful into the session row, and makes the user read an error to learn what the app could
  have known.
- `--print` with a JSON stream was rejected for the same reason as `codex exec`: it removes the
  interactive session that is the point of the product.
- Shipping the model aliases (`opus`, `sonnet`, `haiku`) as a fallback list was rejected: they are
  accepted by the CLI when a user types them, but a list *we* display must reflect the account's
  own entitlements, which only the cache knows.
- Reading `~/.claude/.credentials.json` or the keychain to know whether the user is signed in was
  rejected: the application has no business touching credentials.
- Decoding the whole `auth status` answer and keeping only what is needed was rejected in favour of
  a type that cannot hold anything else.
- `--continue` as a simpler resume was rejected: it resumes whatever ran last in that directory.
