#!/bin/zsh

# Checks a release disk image the way a new user meets it (#19, ADR 0021):
#
#   1. Gatekeeper accepts the image and the application in it;
#   2. the application is installed in a folder of its own, its privacy permissions reset;
#   3. the interface smoke test runs against that very binary, on empty data and defaults;
#   4. its terminal host refuses a binary signed ad hoc under the application's identifier
#      (security review A6).
#
#   Scripts/clean-install-check.sh "build/release/1.0.0/Vibe Manager 1.0.0.dmg"
#
# It needs a logged-in graphical session, and the Mac it runs on is never quite clean — PATH,
# signed-in CLIs. The release checklist adds a pass on a fresh macOS 14 virtual machine.

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly bundle_identifier="com.hadrienl.VibeManager"
readonly image="${1:-}"

fail() {
  print -u2 "clean-install-check: $*"
  exit 1
}

step() {
  print "\n==> $*"
}

[[ -f "$image" ]] || fail "usage: Scripts/clean-install-check.sh <disk image>"

readonly work="$(mktemp -d "${TMPDIR:-/tmp}/vibe-clean-install.XXXXXX")"
readonly mountpoint="$work/volume"
readonly applications="$work/Applications"
readonly app="$applications/Vibe Manager.app"
host_pid=""

cleanup() {
  [[ -n "$host_pid" ]] && kill "$host_pid" 2>/dev/null || true
  hdiutil detach -quiet "$mountpoint" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

step "Gatekeeper, on the disk image"
spctl -a -vvv -t open --context context:primary-signature "$image" \
  || fail "Gatekeeper rejects the disk image"
xcrun stapler validate "$image" || fail "the disk image carries no notarization ticket"

step "Installing"
mkdir -p "$mountpoint" "$applications"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mountpoint" "$image"
ditto "$mountpoint/Vibe Manager.app" "$app"
hdiutil detach -quiet "$mountpoint"

step "Gatekeeper, on the application"
spctl -a -vvv -t exec "$app" || fail "Gatekeeper rejects the application"
codesign --verify --deep --strict "$app" || fail "the application's signature does not verify"
xcrun stapler validate "$app" || fail "the application carries no notarization ticket"

step "Forgetting every permission granted to $bundle_identifier"
tccutil reset All "$bundle_identifier" || true

step "The interface smoke test, against the installed application"
TEST_RUNNER_VIBE_SMOKE_APP="$app" \
  DERIVED_DATA_PATH="$work/DerivedData" \
  "$repository_root/Scripts/ui-smoke.sh"

step "The terminal host refuses an ad hoc binary carrying the application's identifier"
readonly host_directory="$work/host"
readonly logs="$work/logs"
mkdir -p "$host_directory" "$logs"
"$app/Contents/MacOS/Vibe Manager" --terminal-host "$host_directory" --log-directory "$logs" &
host_pid=$!
readonly socket="$host_directory/host-v1.sock"
for _ in {1..100}; do
  [[ -S "$socket" ]] && break
  sleep 0.1
done
[[ -S "$socket" ]] || fail "the terminal host did not start listening"
# Any client will do; what matters is how it is signed.
readonly impostor="$work/impostor"
cp /usr/bin/nc "$impostor"
codesign --force --sign - --identifier "$bundle_identifier" "$impostor"
print "impostor" | "$impostor" -U -w 2 "$socket" >/dev/null 2>&1 || true
for _ in {1..50}; do
  grep -q '"host.peerRefused"' "$logs/host.jsonl" 2>/dev/null && break
  sleep 0.1
done
grep -q '"host.peerRefused"' "$logs/host.jsonl" 2>/dev/null \
  || fail "the terminal host did not refuse the ad hoc binary"
kill "$host_pid" 2>/dev/null || true
host_pid=""

print "\nClean install check passed for $(basename "$image")."
