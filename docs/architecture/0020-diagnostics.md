# 0020 — Diagnostics: a log that cannot leak, and an export the user reads first

- Status: accepted
- Date: 2026-09-24
- Issue: [#19](https://github.com/hadrienl/vibe-manager/issues/19)
- Supersedes: ADR 0003's `AgentDiagnostic.redact(path:)`, replaced by `RedactedPath`

## Context

Until #19, the application wrote nothing about itself. The terminal host had one `Logger` with three
fixed messages, and `AgentDiagnostic` was only shown on screen. A user whose sessions did not come
back after a crash had nothing to send, and nobody had anything to read.

A log in this application has an unusual problem: almost everything it handles is private. Session
names, prompts, notes, folder names, terminal output, the environment given to an agent (proxy
variables may carry credentials) — any of them in a log file is a leak waiting for a bug report.
The ticket makes it an acceptance criterion: no prompt, token or secret in the logs by default.

## Decisions

### Safe by type, not by care

`DiagnosticEvent` has no place for free text.

- Its name is a `StaticString`, and so is every field name: they can only be literals of the
  source.
- A field's value is a `DiagnosticValue`: a count, a size, a duration, a flag, a code (`errno`,
  `OSStatus`, exit status, signal), a `DiagnosticToken`, a `SessionPseudonym`, a `RedactedPath` or
  a `DiagnosticVersion`. There is no `String` case.
- A `DiagnosticToken` is built from a `StaticString` literal, or from the raw value of an
  enumeration declared `DiagnosticTokenConvertible`. `AgentProviderID`, which could be read back
  from an old store, names only the providers this build knows and says `other` for the rest.
- An error is logged by its type and its code, never by `localizedDescription`, which carries
  paths and sometimes command output.

A prompt cannot be logged by accident: it does not compile. Debug events, enabled by
`defaults write com.hadrienl.VibeManager DiagnosticsVerbose -bool YES`, are made of the same types:
verbose is not indiscreet.

### Sessions by pseudonym, paths by hash

A session is `s-` and the first 8 hexadecimal characters of an HMAC-SHA256 of its identifier, keyed
by 32 random bytes in `Logs/.salt` (`0600`), created once and never exported. The log and an export
correlate with each other; neither leads back to the store without the salt. The host reads the
same salt, so a session reads the same in `app.jsonl` and `host.jsonl`.

A path becomes a `RedactedPath`: the home folder is `~`, and each component under it is `…` and the
first four hexadecimal characters of its SHA-256, except a short list of tool folders (`.local`,
`bin`, `.npm-global`, `Library`…). The folders tools are installed in (`/usr/local/bin`,
`/opt/homebrew/bin`, `/Applications/Xcode.app`…) stay readable, because a binary not found is
diagnosed by where it was looked for. Anything else is hashed whole.

### Local, bounded, and in two places

`~/Library/Logs/Vibe Manager/` holds `app.jsonl` and `host.jsonl`; an isolated copy writes to
`<VIBE_DATA_DIRECTORY>/Logs/`, and gives the host that folder in its launch arguments
(`--log-directory`) rather than letting it guess. One JSON object per line, written in append from
one serial queue: a caller never waits for the disk. Files are `0600` in a `0700` folder, flushed to
disk only for `error` and `fault`.

A file rotates past 5 MB, or once its first line is a week old, into `<name>.1.jsonl`, which is
removed once its last line is a week old: never more than 10 MB per process, never older than two
weeks. A line that cannot be written — a full disk — is counted, and the count is written as
`diagnostics.linesDropped` once writing works again. Logging never fails or slows the action it
describes.

Every event also goes to the unified log, subsystem `com.hadrienl.VibeManager`, one category per
module, for Console.app and Instruments. It is marked `.public`: its content is safe by
construction.

### What is logged is a closed list

Lifecycle (launch with version, macOS, architecture and signature; the verdict on the previous run;
the quit route; the deadline reached), sessions (created, launched, adopted, exited with state, code
and duration, refused, switched, archived, handed off), the host on both sides (launched, connected,
refused, verification failed, fallback in the application, client attached and detached, idle exit,
stop requested, output truncated), agent detection (provider, state, source, version, duration),
`git` (the verb only, code, duration, timeout, the repository redacted — at `debug` unless it
failed), the store (write failure by `errno`, corruption, restoration, migration, permissions
repaired), notes (read or write failure by `errno`). Adding an event is a pull request that goes
through the same types.

### The export is read before it is saved

Help → Export Diagnostics…, also in Settings and on a store that could not be read. A sheet shows
**the exact text** the archive will hold, file after file, in a read-only view that can be searched,
and says in one sentence what is not in it: what the terminals showed, prompts, notes, the names of
sessions and folders. Save… opens a save panel on `Vibe Manager Diagnostics <date>.zip`. There is
no upload, no mail link, no automatic crash report.

The archive holds `summary.txt` (version, signature, settings), `agents.txt` (each agent's last
detection: state, version, redacted directory, authentication as a token — the export never asks the
agent again), `store.txt` (schema, counts by status, sizes, backup, damaged copies), `runtime.txt`
(the runtime document's phase, the previous verdict, the host's identity and each session's state by
pseudonym), the log lines of the last 7 days, and the system's crash reports of the last 30 days
with every path under the home folder redacted and the user's short name replaced.

Building the files is a pure function of `DiagnosticSnapshot`, which can only hold the types above.
The archive is a ZIP written in memory (deflated with the Compression framework, CRC-32 computed
here): no tool is run.

## Consequences

- A bug report can carry an export without the user having to trust anything they did not read.
- A new event costs a line, and a new kind of value costs a review: the types are the policy.
- The canary scenario of #19 (sessions whose name, prompt, notes, folder, proxy variable and terminal
  output all carry `VIBE-CANARY-<uuid>`) reads `app.jsonl`, `host.jsonl` and the export, in clear and
  in base64, and fails on the slightest occurrence.
- `RedactedPath` hashes are short on purpose: they tell two folders apart in one export, they are
  not meant to resist a dictionary of the user's own folder names, which the salt-less hash does not
  claim to.

## Rejected alternatives

- **A string log with a redaction pass.** Every redaction list misses the next field someone adds.
- **Sending crash reports.** Not in V1, and never without the user choosing to.
- **Reading `auth status` again at export time.** The export would then run the agent's CLI, which
  may print an account or an organisation, at the one moment the user expects a read-only action.
