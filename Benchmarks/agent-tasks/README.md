# Reference tasks for agents on endpoints (#107)

Six tasks that say whether a model served by an endpoint, driven by Claude Code or Codex through
the gateway, works as well as the same model served by its own provider. The threshold of #107:
at least **90 %** of the success rate of the original provider, with the same model.

| Task | What it exercises |
|---|---|
| `fix-failing-test` | Reading, running tests, a one-line fix |
| `multi-file-feature` | A feature across three files, judged by hidden tests |
| `refactor` | Merging two functions, updating every caller, keeping behaviour |
| `code-question` | Answering from the code without changing it |
| `many-tool-calls` | More than twenty tool calls in a row, one edit per file |
| `context-overflow` | Four megabytes of logs: grep, or compaction |

Each task is a folder: `repo/` (the starting files), an optional `setup.sh <repo> <private>`
that generates more, `prompt.md`, and `verify.sh <repo> <answer> <private>` whose exit code is
the verdict. `private/` holds what the agent must not see, such as an expected answer.

## Running

```sh
swift build --package-path Packages/VibeManagerKit --product vibe-gateway

# The reference: the model through its own provider.
Scripts/agent-bench --harness claude --model claude-sonnet-5-5 --label sonnet-direct

# The same model through an endpoint that speaks Chat Completions.
OPENROUTER_API_KEY=… Scripts/agent-bench --harness claude --model anthropic/claude-sonnet-5.5 \
  --label sonnet-openrouter --context 200000 \
  --gateway "--base-url https://openrouter.ai/api/v1 --protocol chatCompletions --secret-env OPENROUTER_API_KEY"
```

Three runs per task by default: a model does not answer the same way twice. Results go to
`Benchmarks/results/<date>-<label>.json` and `.md`, committed with the decision they support
(ADR 0032). The runs cost money and depend on the network: they never run in CI.
