#!/bin/zsh

# `Scripts/check-external-opens.sh` against sources written for the occasion: it refuses a direct
# open that gives no reason, and accepts one that does, on its line or the one above. Run by
# `Scripts/ci.sh`.

set -euo pipefail

readonly check="${0:A:h}/check-external-opens.sh"
readonly fixtures="$(mktemp -d)"
trap 'rm -rf "$fixtures"' EXIT

# A Swift file holding `body`.
source_file() {
  local name="$1" body="$2"
  print -r -- "$body" > "$fixtures/$name.swift"
  print -r -- "$fixtures/$name.swift"
}

expect() {
  local outcome="$1" description="$2" file="$3"
  if "$check" "$file" > /dev/null 2>&1; then
    [[ "$outcome" == accepted ]] || { echo "FAIL: $description was accepted" >&2; exit 1; }
  else
    [[ "$outcome" == refused ]] || { echo "FAIL: $description was refused" >&2; exit 1; }
  fi
  echo "ok: $description $outcome"
}

expect accepted "a file that opens nothing" "$(source_file none 'let url = URL(string: "https://example.com")')"
expect refused "a direct open without a reason" "$(source_file bare '
func open(_ url: URL) {
  NSWorkspace.shared.open(url)
}')"
expect accepted "a direct open with its reason above" "$(source_file above '
func open(_ url: URL) {
  // Opens outside: a constant address of System Settings.
  NSWorkspace.shared.open(url)
}')"
expect accepted "a direct open with its reason on its line" "$(source_file inline '
if LinkRouting.isPage(url) { NSWorkspace.shared.open(url) }  // Opens outside: a page.')"
expect refused "a reason too far above" "$(source_file far '
// Opens outside: a page.
let other = 1
NSWorkspace.shared.open(url)')"
