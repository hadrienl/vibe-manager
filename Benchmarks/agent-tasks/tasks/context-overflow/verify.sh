#!/bin/sh
# $2 is the agent's final answer, $3 the task's private folder.
cd "$1" || exit 2
git diff --quiet || { echo "files were changed"; exit 1; }
read component total < "$3/expected"
grep -qiw "$component" "$2" || { echo "missing $component"; exit 1; }
grep -qw "$total" "$2" || { echo "missing total $total"; exit 1; }
