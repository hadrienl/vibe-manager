#!/bin/zsh

# A Release build to try out before a pull request is merged or a version tagged, named after what
# it carries: "Vibe Manager #159" in the Dock, ⌘⇥, the menu bar and the window's title, so that
# several copies running side by side can be told apart.
#
#   Scripts/local-build.sh          # labelled after the branch's ticket (#159), or the commit
#   Scripts/local-build.sh "#159 b" # labelled as given
#
# The application lands in ~/Downloads/VibeManager-local-<commit>/. It keeps the bundle identifier
# and the Apple Development signature of a local build: only its name changes, and it is signed
# again after that. Launch it as an isolated copy (VIBE_DATA_DIRECTORY, VIBE_DEFAULTS_SUITE):
# opened from the Finder, it would read the store of the application in use.

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly commit="$(git -C "$repository_root" rev-parse --short HEAD)"
readonly branch="$(git -C "$repository_root" branch --show-current)"

fail() {
  print -u2 "local-build: $*"
  exit 1
}

# The ticket in the branch's name — feat/159-window-title, fix/106-… — or else the commit.
label="${1:-}"
if [[ -z "$label" ]]; then
  if [[ "$branch" =~ '/([0-9]+)(-|$)' ]]; then
    label="#${match[1]}"
  else
    label="$commit"
  fi
fi
readonly label
readonly name="Vibe Manager $label"
readonly derived_data="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/vibe-local-build-$commit}"
readonly destination="$HOME/Downloads/VibeManager-local-$commit"

print "==> Building $name ($commit)"
xcodebuild \
  -project "$repository_root/VibeManager.xcodeproj" \
  -scheme VibeManager \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates \
  MARKETING_VERSION="1.0.0-local" \
  VIBE_EMBED_COMPANION=YES \
  build | grep -E '(error|warning):|\*\* BUILD' || true

readonly built="$derived_data/Build/Products/Release/Vibe Manager.app"
[[ -d "$built" ]] || fail "no application was built at $built"

print "==> Naming it $name"
rm -rf "$destination/$name.app"
mkdir -p "$destination"
readonly app="$destination/$name.app"
ditto "$built" "$app"
# The localized names win over Info.plist's: every one of them is replaced.
for plist in "$app/Contents/Info.plist" "$app"/Contents/Resources/*.lproj/InfoPlist.strings(N); do
  plutil -replace CFBundleDisplayName -string "$name" "$plist"
  plutil -replace CFBundleName -string "$name" "$plist"
done

# The same identity as the build's: the terminal host only accepts a peer signed as itself, and
# the privacy permissions follow the identifier and the team.
readonly identity="$(codesign -dvv "$built" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ -n "$identity" ]] || fail "the build is not signed with an identity"
codesign --force --preserve-metadata=identifier,entitlements,flags,runtime \
  --sign "$identity" "$app"
codesign --verify --strict "$app" || fail "the renamed application does not verify"

# The mobile companion's agent (#347), embedded: it holds iCloud and the pushes, signed with its own
# profile, and the application keeps the microphone alone (ADR 0021). Checked in the final bundle,
# where an entitlement lost in a copy would only show when CloudKit refuses.
readonly agent="$app/Contents/Helpers/Vibe Manager Companion.app"
[[ -d "$agent" ]] || fail "the companion agent is not embedded"
codesign --verify --deep --strict "$app" || fail "the embedded companion agent does not verify"
[[ -f "$agent/Contents/embedded.provisionprofile" ]] \
  || fail "the companion agent carries no provisioning profile"
readonly agent_entitlements="$(codesign -d --entitlements - --xml "$agent" 2>/dev/null \
  | plutil -convert json -o - - 2>/dev/null || true)"
[[ "$agent_entitlements" == *'"com.apple.developer.icloud-services":["CloudKit"]'* \
  && "$agent_entitlements" == *'"com.apple.developer.aps-environment"'* ]] \
  || fail "the companion agent lacks its iCloud or push entitlement: $agent_entitlements"
# get-task-allow comes with the development signature of every local build, not from the project.
[[ "$(codesign -d --entitlements - --xml "$app" 2>/dev/null \
  | plutil -remove 'com\.apple\.security\.get-task-allow' -o - - 2>/dev/null \
  | plutil -convert json -o - -)" == '{"com.apple.security.device.audio-input":true}' ]] \
  || fail "the application's entitlements are not the microphone's alone (ADR 0021)"

rm -rf "$derived_data"
print "==> $app"
