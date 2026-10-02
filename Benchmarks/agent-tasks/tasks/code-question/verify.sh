#!/bin/sh
# $2 is the agent's final answer. Both facts must be in it, and nothing changed.
cd "$1" || exit 2
git diff --quiet || { echo "files were changed"; exit 1; }
grep -q "413" "$2" || { echo "no 413 in the answer"; exit 1; }
grep -qw 25 "$2" || { echo "no 25 in the answer"; exit 1; }
