#!/bin/sh
# Minimal stand-in for a coding agent CLI.
# It exists so Vibe Manager can exercise launching, streaming and resuming without
# Claude, Codex, an account or a network call.

set -eu

model="mock-fast"
prompt=""
resume=""
exit_code=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      echo "mock-agent 1.0.0"
      exit 0
      ;;
    --model)
      model="${2:-}"
      shift 2
      ;;
    --resume)
      resume="${2:-}"
      shift 2
      ;;
    --prompt)
      prompt="${2:-}"
      shift 2
      ;;
    --prompt-from-stdin)
      prompt="$(cat)"
      shift
      ;;
    --fail)
      exit_code="${2:-1}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "$resume" ]; then
  echo "mock-session-id: $resume"
  echo "Resuming mock session."
else
  echo "mock-session-id: mock-$(date +%s)-$$"
  echo "Starting mock session."
fi

echo "model: $model"
echo "cwd: $(pwd)"

if [ -n "$prompt" ]; then
  printf 'prompt: %s\n' "$prompt"
fi

echo "Mock agent finished."
exit "$exit_code"
