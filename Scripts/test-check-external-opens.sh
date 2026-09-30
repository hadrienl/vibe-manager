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
expect accepted "an open that is not safe yet, tracked by its issue" "$(source_file tracked '
// Unsafe open, to fix in #241: a link of the page hands another application'"'"'s address over.
NSWorkspace.shared.open(target)')"
expect accepted "the way out every address is meant to take" "$(source_file routed '
import AppKit
func show(_ url: URL) { ExternalOpening.open(url) }')"
expect accepted "a function named open, declared" "$(source_file declared '
import AppKit
func open(_ url: URL, with editor: EditorChoice) async -> Bool { false }')"

# The ways around the first version of this check, found in the review of #245.
expect refused "a space before the parenthesis" "$(source_file a_space 'NSWorkspace.shared.open (url)')"
expect refused "a space inside the receiver" "$(source_file b_space 'NSWorkspace .shared.open(url)')"
expect refused "the workspace in a variable" "$(source_file c_var '
let ws = NSWorkspace.shared
ws.open(url)')"
expect refused "an application opened" "$(source_file d_openapp '
NSWorkspace.shared.openApplication(at: app, configuration: .init())')"
expect refused "a named application" "$(source_file e_withapp '
NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())')"
expect refused "a call cut over two lines" "$(source_file f_chain '
NSWorkspace.shared
  .open(url)')"
expect refused "the open command run by a process" "$(source_file g_process '
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [url.path]')"
expect refused "the method taken as a value" "$(source_file h_ref 'let o = NSWorkspace.shared.open; o(url)')"
expect refused "the mark inside a string" "$(source_file i_string '
let s = "// Opens outside:"; NSWorkspace.shared.open(url)')"
expect refused "a mark without a reason" "$(source_file j_empty '
// Opens outside:
NSWorkspace.shared.open(url)')"
expect refused "a mark in a block comment" "$(source_file k_block '
/* Opens outside: x */ NSWorkspace.shared.open(url)')"
expect refused "an open under another one's reason" "$(source_file l_chain '
NSWorkspace.shared.open(url) // Opens outside: first
NSWorkspace.shared.open(evil)')"
expect refused "SwiftUI's openURL" "$(source_file m_openurl '
@Environment(\.openURL) var openURL
func go() { openURL(url) }')"
expect refused "Launch Services" "$(source_file n_ls 'LSOpenCFURLRef(url as CFURL, nil)')"
