#!/bin/zsh

# Every address the application hands to macOS goes through `LinkRouting`, which lets out a page or
# a mail address and nothing that would run (#245). A direct `NSWorkspace.shared.open(` is refused
# unless it says, on its line or the one above, why it is safe: `// Opens outside: <reason>`.
# Given files, checks them; otherwise the application's and the package's sources. Run by
# `Scripts/ci.sh`.

set -euo pipefail

readonly repository_root="${0:A:h:h}"

if (( $# > 0 )); then
  sources=("$@")
else
  cd "$repository_root"
  sources=(App/**/*.swift(N) Packages/*/Sources/**/*.swift(N))
fi

failures=0
for file in $sources; do
  previous=""
  number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    (( number += 1 ))
    if [[ "$line" == *"NSWorkspace.shared.open("* ]] \
      && [[ "$line" != *"// Opens outside:"* ]] \
      && [[ "$previous" != *"// Opens outside:"* ]]
    then
      echo "$file:$number: a direct NSWorkspace.shared.open without « // Opens outside: <reason> »" >&2
      (( failures += 1 ))
    fi
    previous="$line"
  done < "$file"
done

if (( failures > 0 )); then
  echo "Route the address through LinkRouting, or say why it is safe to open." >&2
  exit 1
fi
