# Endpoints

An endpoint is a model server reachable over HTTP — on this Mac (Ollama, LM Studio) or in the cloud
(OpenRouter, a corporate gateway such as the Prisme.ai LLM Gateway). Its models appear beside Claude
Code and Codex when you create a session, and the session runs Claude Code or Codex against them:
same terminal, same conversation view, same requests in the palette, same resume after a relaunch.
The design is in [ADR 0035](architecture/0035-endpoint-agents.md).

## Adding one

Settings → Endpoints → **+**, then a starting point:

| Starting point | URL | Protocol | Key |
|---|---|---|---|
| Ollama | `http://localhost:11434` | Anthropic Messages | none |
| LM Studio | `http://localhost:1234/v1` | OpenAI Chat Completions | none |
| OpenRouter | `https://openrouter.ai/api/v1` | OpenAI Chat Completions | bearer token |
| Prisme.ai LLM Gateway | `https://<host>/v2/workspaces/slug:llm-gateway/webhooks/v1` | OpenAI Chat Completions | `x-prismeai-api-key` header |
| OpenAI-compatible, Anthropic-compatible | yours | as named | as the server wants |

- **Key**: typed once, written to the login keychain (service `com.hadrienl.VibeManager.endpoint`,
  one item per endpoint, never synchronised), never shown again. Deleting the endpoint deletes it.
- **Models**: *Read from the Endpoint* lists what the server offers, with what it says of each
  (context window, tools, vision, price). A model that cannot call tools is kept but not offered:
  without tools, an agent can read no file. Give each model its real context window — the harness
  compacts the conversation before it is reached.
- **Driven by**: *Automatic* picks Claude Code for a Messages endpoint and Codex for a Responses
  one (no translation at all), Claude Code for the rest.
- **Advanced**: extra headers, a JSON object merged into every request (`{"provider": {"sort":
  "throughput"}}` for OpenRouter), timeouts.

**Test** sends a short request asking the model to call a tool, then gives it the result, and says
what worked: reachable, authentication, streamed answer and speed, tool call, answer after the
tool, tokens reported. The dot beside the endpoint in the list keeps the verdict; an endpoint whose
last test failed is not offered for new sessions until it passes.

## Using one

Pick the endpoint among the agents of the new session sheet, and one of its models. The session
starts its harness with a token of its own that leads to the gateway; the key stays with the
gateway. Switching to another model of the same endpoint resumes the conversation; switching to
another agent hands over a summary, as between Claude Code and Codex.

Journal summaries, conversation themes and avatars are not made by endpoint sessions: they would
run the harness on your own account with its maker, and send it the session's content.

## The gateway

A process of the application's own binary, `Vibe Manager --endpoint-gateway`, started when a
session on an endpoint starts, listening on `127.0.0.1` only. It keeps running while such sessions
run — after the application quits too, for the sessions the terminal host keeps — and stops by
itself once the application has noticed that the last one ended, within a few minutes.

Its files are in the data folder, under `Gateway/`: `routes.json` (session tokens, private to you),
`gateway.json` (its port) and `steps/` (what an agent on the server did, and the waits before a
new attempt, shown in the conversation).

## When something fails

- **Rate limit, 5xx, lost connection** before the answer starts: retried up to five times within two
  minutes, the waits shown in the conversation. After the answer started: the harness retries the
  turn itself.
- **Key refused**: not retried; the session says so. Replace the key in Settings → Endpoints.
- **Local server not running**: *The endpoint cannot be reached*. Start it and try the turn again.
- **The conversation is too long for the model**: the harness compacts it, at the window you gave.

## Measuring

`Scripts/agent-bench` runs the reference tasks of `Benchmarks/agent-tasks` on a model through its
own provider or through an endpoint; see [the benchmark's README](../Benchmarks/agent-tasks/README.md).
