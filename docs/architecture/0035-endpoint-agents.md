# 0035 — Agents on any model endpoint

- Status: proposed — the reference tasks decide (see "Measurements")
- Date: 2026-09-30
- Issue: [#107](https://github.com/hadrienl/vibe-manager/issues/107)

## Context

A session runs Claude Code or Codex, and everything that makes a session worth having is built on
those CLIs: the terminal host runs a process in a PTY (ADR 0017), the conversation view reads the
CLI's transcript (ADR 0025), usage is read from it too (ADR 0019), activity and requests come from
the CLI's hooks and are answered by typing into its TUI (ADR 0022, 0026), resume hands the CLI its
own identifier (ADR 0011), and the web view's tools are an MCP server the CLI loads (ADR 0023).

#107 asks for sessions on any model reachable over HTTP — a local Ollama, OpenRouter, a corporate
gateway — as good as a Claude Code or Codex session. Three ways were weighed: point an existing
harness at the endpoint through a translating proxy (A), drive a multi-provider open source harness
(B), or write a harness in Swift (C). A keeps every integration above as it is; B adds a third CLI
to integrate everywhere; C would rewrite them all, and is where agent quality is hardest to reach.

Two facts shaped A: Codex speaks only the OpenAI Responses API since February 2026, and Claude Code
only the Anthropic Messages API. A translation is needed for every other protocol.

## Decisions

### A session on an endpoint is a session of Claude Code or Codex

An endpoint the user declares is registered among the agents as `endpoint.<uuid>`
(`EndpointAgentProvider`). Its sessions run the harness its settings name — Claude Code or Codex,
"automatic" choosing the one that needs no translation — pointed at a local gateway. The provider
relays every capability of the harness: activity, MCP tools, conversation, launch observation. The
conversation records the harness actually launched (`SessionAgentConfiguration.harnessID`), since
its transcript is where that CLI writes: the readers of usage, journal and branch report follow it
rather than the agent's identifier.

Not relayed, on purpose: journal summaries, conversation themes and avatars. They run the CLI once,
on the user's account with its maker, and would send an endpoint session's content to a provider
the user chose not to use for it.

### The gateway translates through one canonical shape

`VibeEndpoints` reads the harness's protocol (Messages or Responses) into a canonical request —
turns, text, images, tool calls and results, reasoning — and writes it in the endpoint's protocol
(Chat Completions, Responses or Messages); the answer comes back the same way, streamed. Six
adapters rather than six pairwise translations. When both sides speak the same protocol, the body
goes through as it came, with the endpoint's model and credentials.

What each side needs was found by running the real CLIs against a scripted endpoint: Claude Code
sends a `HEAD` before its first request and `system` messages in the middle of a conversation;
Codex offers custom tools (`apply_patch`) that other endpoints only accept as functions. Tool calls
of a Chat Completions stream are handed over whole at the end of the answer: endpoints interleave
their fragments, which the Messages protocol cannot express, and their JSON is repaired when only
its end is missing.

### The gateway is a process of its own, driven by files

`Vibe Manager --endpoint-gateway <dir>` is started detached, like the terminal host, when a session
on an endpoint is about to start — never when a form merely builds a launch plan
(`AgentLaunchPreparing`). It is not the host: a translation bug must not take down every terminal.

There is no protocol between the application and the gateway. The application writes which session
token leads to which endpoint and model (`Gateway/routes.json`, mode 0600); the gateway reads it and
`endpoints.json` again when they change, reads the endpoint's key from the keychain on each
request, and writes the port it listens on (`gateway.json`), which it reuses after a restart. It
outlives the application while tokens remain, so sessions the host kept still reach their model,
and stops by itself once none is left: the application removes the tokens of sessions that ended.

A session's harness is given the gateway's URL and a random 256-bit token of its own, never the
endpoint's key. The token must come back in the harness's own credential header, not only in the
path.

### Failures are retried where the harness cannot see them

Before anything of an answer has reached the harness, a rate limit (honouring `Retry-After`), a 5xx,
a lost connection or a silence is tried again, up to five times within two minutes. After, the
failure is written in the harness's own stream as the error it retries by itself (Claude Code's
`overloaded_error`, Codex's failed response), so the turn is not lost. Timeouts are set per
endpoint: connection, first byte (long, for a local model loading), silence, whole answer.

### The context window is the endpoint's

The harness is told the model's window: Claude Code 2.1 reads `CLAUDE_CODE_MAX_CONTEXT_TOKENS` for
an unknown model and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` for when to compact (both found in its code);
Codex takes `model_context_window` and `model_auto_compact_token_limit`. Without them the harness
assumes the window of its maker's models, and a smaller model refuses the conversation before it is
ever compacted.

### An endpoint that follows no standard is described, not programmed

A custom endpoint carries a JSON document: a request template with named values of the
conversation (`{{messages:openai}}`, `{{lastUserText}}`…), the framing of its answer (SSE, JSON
lines or one object), and rules that match each object of the answer by a path and a comparison and
say what it holds — text, reasoning, a tool call, a server step, usage, an error, the end. No
scripting: a need the document cannot express adds a named value to the code, with a test. The
document is checked as it is typed, and one that does not read cannot be saved.

### What an agent on the server does is shown, not replayed

An endpoint may run tools of its own (Responses' hosted tools, Anthropic's server tools). They are
steps, not calls for the harness: the gateway keeps them, with its waits before another attempt, in
`Gateway/steps/<session>.jsonl`, and the conversation view places each by date among the harness's
entries.

## Measurements

The six reference tasks of `Benchmarks/agent-tasks` and `Scripts/agent-bench` compare the same
model through its own provider and through an endpoint. The threshold is 90 % of the original
provider's success rate. **They have not been run yet**: they need API keys and cost money. Until
they are, the choice of A rests on the integration argument above and on the end-to-end runs of both
real CLIs against a scripted endpoint, which went through reading, a tool call, its result and the
usage. This record moves to "accepted" with the results committed beside it, or is revised if they
fall short.

## Consequences

- An endpoint is configured in Settings → Endpoints: URL, protocol, key (in the keychain), models
  read from the endpoint when it lists them, and a test that asks the model to call a tool.
- Sessions on an endpoint have the terminal, the conversation view, the requests, the web view's
  tools, resume and usage of their harness.
- Diagnostics log every endpoint under one token, `endpoint`.

## Known limits

- The gateway is started again by the application only: if it dies while the application is away,
  the sessions the host kept fail their next turn until the application returns.
- For a model it does not know, Codex uses fallback metadata and offers no `apply_patch`: it edits
  through the shell. The benchmark says what that costs.
- An endpoint's price is kept per model but no cost is shown: ADR 0019 computes none.
