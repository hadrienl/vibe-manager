#!/bin/sh
# Minimal stand-in for a coding agent CLI.
# It exists so Vibe Manager can exercise launching, streaming and resuming without
# Claude, Codex, an account or a network call.
#
# The scenario tests of #19 drive it further:
#   --hold               stay alive, and echo every line typed as "echo: <line>"
#   --flood <KiB/s>      write that much output per second, in the background, until killed
#   --ignore-sigterm     survive SIGTERM: only SIGKILL stops it
#   --ignore-sighup      survive the hang-up of its terminal
#   --spawn-child        start a child that ignores SIGTERM and SIGHUP, and print its pid
#   --session-id <id>    the resume identifier to print, instead of one made from the clock
#
# While holding, a line `run:<command>` runs that command through `sh`, as a CLI's shell tool does,
# and prints its output then `run-exit: <status>` — how the scenarios of #69 reach `vibe`.
#
# With VIBE_AGENT_ACTIVITY_LOG set, it reports its activity the way the hooks of a real CLI do
# (#45): `SessionStart` when it starts, and, while holding, `UserPromptSubmit` then `Stop` for
# every line typed — or exactly the event a line names, as `event:PermissionRequest`.

set -eu

report() {
  if [ -n "${VIBE_AGENT_ACTIVITY_LOG:-}" ]; then
    printf '%s\t%s\t\n' "$1" "$(date +%s)" >>"$VIBE_AGENT_ACTIVITY_LOG"
  fi
}

model="mock-fast"
prompt=""
resume=""
session_id=""
exit_code=0
hold=0
flood=""
spawn_child=0

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
    --hold)
      hold=1
      shift
      ;;
    --flood)
      flood="${2:-}"
      shift 2
      ;;
    --ignore-sigterm)
      trap '' TERM
      shift
      ;;
    --ignore-sighup)
      trap '' HUP
      shift
      ;;
    --spawn-child)
      spawn_child=1
      shift
      ;;
    --session-id)
      session_id="${2:-}"
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
elif [ -n "$session_id" ]; then
  echo "mock-session-id: $session_id"
  echo "Starting mock session."
else
  echo "mock-session-id: mock-$(date +%s)-$$"
  echo "Starting mock session."
fi

report SessionStart
echo "model: $model"
echo "cwd: $(pwd)"

if [ -n "$prompt" ]; then
  printf 'prompt: %s\n' "$prompt"
fi

if [ "$spawn_child" -eq 1 ]; then
  /bin/sh -c 'trap "" TERM HUP; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &
  echo "mock-child: $!"
fi

if [ -n "$flood" ]; then
  # 16 KiB a burst, as many bursts a second as the rate asks for.
  interval="$(awk "BEGIN { printf \"%.4f\", 16 / $flood }")"
  (
    block="$(awk 'BEGIN { for (i = 0; i < 256; i++) printf "flood-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789-ABCDEFGH\n" }')"
    while :; do
      printf '%s\n' "$block"
      sleep "$interval"
    done
  ) &
fi

if [ "$hold" -eq 1 ]; then
  echo "Holding."
  while IFS= read -r line; do
    case "$line" in
      event:*)
        report "${line#event:}"
        ;;
      run:*)
        status=0
        /bin/sh -c "${line#run:}" 2>&1 || status=$?
        printf 'run-exit: %s\n' "$status"
        ;;
      *)
        report UserPromptSubmit
        printf 'echo: %s\n' "$line"
        report Stop
        ;;
    esac
  done
fi

report SessionEnd
echo "Mock agent finished."
exit "$exit_code"
