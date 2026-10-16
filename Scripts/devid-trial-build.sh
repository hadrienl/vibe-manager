#!/bin/zsh

# A trial of the release of the mobile companion (#368): the application signed with its Developer
# ID and the hardened runtime, as Scripts/release.sh signs it, with the companion's agent embedded
# in Contents/Helpers — which a release does not do yet. Neither notarized nor published.
#
#   Scripts/devid-trial-build.sh                 # the agent's profile made by Xcode (automatic)
#   VIBE_AGENT_PROFILE="<name or UUID>" \
#     Scripts/devid-trial-build.sh               # a Developer ID profile made in the portal
#
# The agent holds iCloud and the pushes: they need a Developer ID provisioning profile of its own
# App ID (eu.hadrien.VibeManager.CompanionAgent), with iCloud (CloudKit, iCloud.eu.hadrien.VibeManager)
# and Push Notifications. Xcode makes it when its account can (Settings → Accounts, signed in, and
# a role allowed to); otherwise it is made in the portal, installed, and named here.
#
# CloudKit stays in Development for the whole of #347 (CompanionBase.xcconfig): Xcode's export only
# offers Production to a Developer ID, so the agent is signed again with Development, if its
# profile allows it. If not, the build stops: Production needs the schema deployed, a decision of
# its own.
#
# The application lands in ~/Downloads/VibeManager-devid-<commit>/, named "Vibe Manager #368 devid
# <commit>". Launch it as an isolated copy (VIBE_DATA_DIRECTORY, VIBE_DEFAULTS_SUITE).

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly commit="$(git -C "$repository_root" rev-parse --short HEAD)"
readonly team="QMJKZ67Z3H"
readonly agent_identifier="eu.hadrien.VibeManager.CompanionAgent"
readonly name="Vibe Manager #368 devid $commit"
readonly work="${WORK_PATH:-${TMPDIR:-/tmp}/vibe-devid-$commit}"
readonly destination="$HOME/Downloads/VibeManager-devid-$commit"

fail() {
  print -u2 "devid-trial-build: $*"
  exit 1
}

readonly identity="$(security find-identity -v -p codesigning \
  | sed -n "s/.*\"\(Developer ID Application: .*($team)\)\"/\1/p" | head -1)"
[[ -n "$identity" ]] || fail "no Developer ID Application identity of team $team"

rm -rf "$work"
mkdir -p "$work"
readonly archive="$work/Vibe Manager.xcarchive"

# Archived as Debug builds sign, automatically and Apple Development: the export signs again.
print "==> Archiving ($commit)"
xcodebuild \
  -project "$repository_root/VibeManager.xcodeproj" \
  -scheme VibeManager \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$work/derived" \
  -archivePath "$archive" \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates \
  MARKETING_VERSION="1.0.0-devid" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  VIBE_EMBED_COMPANION=YES \
  archive | grep -E '(error|warning):|\*\* ARCHIVE' || true
[[ -d "$archive" ]] || fail "no archive was made"
rm -rf "$work/derived"

print "==> Exporting with $identity"
readonly options="$work/ExportOptions.plist"
plutil -create xml1 "$options"
plutil -insert method -string developer-id "$options"
plutil -insert teamID -string "$team" "$options"
plutil -insert destination -string export "$options"
if [[ -n "${VIBE_AGENT_PROFILE:-}" ]]; then
  plutil -insert signingStyle -string manual "$options"
  plutil -insert signingCertificate -string "$identity" "$options"
  plutil -insert provisioningProfiles -dictionary "$options"
  plutil -insert "provisioningProfiles.${agent_identifier//./\\.}" -string "$VIBE_AGENT_PROFILE" \
    "$options"
else
  plutil -insert signingStyle -string automatic "$options"
fi
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" \
  -exportOptionsPlist "$options" -allowProvisioningUpdates \
  || fail "the export failed: see the agent's profile above"
rm -rf "$archive"
readonly exported="$work/export/Vibe Manager.app"
readonly exported_agent="$exported/Contents/Helpers/Vibe Manager Companion.app"
[[ -d "$exported_agent" ]] || fail "the companion agent is not embedded"

print "==> Naming it $name"
rm -rf "$destination"
mkdir -p "$destination"
readonly app="$destination/$name.app"
ditto "$exported" "$app"
rm -rf "$work"
readonly agent="$app/Contents/Helpers/Vibe Manager Companion.app"

# What the agent's profile allows, and so what its entitlements may say.
readonly profile_entitlements="$(security cms -D -i "$agent/Contents/embedded.provisionprofile" \
  | plutil -extract Entitlements xml1 -o - -)"
allows() {
  print -r -- "$profile_entitlements" | plutil -extract "$1" json -o - - 2>/dev/null \
    | grep -q "\"$2\""
}
allows 'com\.apple\.developer\.icloud-container-environment' Development \
  || fail "the agent's Developer ID profile does not allow CloudKit's Development environment: $(
    print -r -- "$profile_entitlements" \
      | plutil -extract 'com\.apple\.developer\.icloud-container-environment' json -o - -)"
aps_environment=production
allows 'com\.apple\.developer\.aps-environment' development && aps_environment=development

print "==> Agent: CloudKit Development, pushes $aps_environment"
readonly agent_entitlements="$destination/agent.entitlements"
codesign -d --entitlements - --xml "$agent" > "$agent_entitlements"
plutil -replace 'com\.apple\.developer\.icloud-container-environment' -string Development \
  "$agent_entitlements"
plutil -replace 'com\.apple\.developer\.aps-environment' -string "$aps_environment" \
  "$agent_entitlements"
codesign --force --timestamp --options runtime --entitlements "$agent_entitlements" \
  --sign "$identity" "$agent"
rm "$agent_entitlements"

# The localized names win over Info.plist's: every one of them is replaced. Then the application is
# sealed again, as itself — the agent inside keeps its own signature and profile.
for plist in "$app/Contents/Info.plist" "$app"/Contents/Resources/*.lproj/InfoPlist.strings(N); do
  plutil -replace CFBundleDisplayName -string "$name" "$plist"
  plutil -replace CFBundleName -string "$name" "$plist"
done
codesign --force --timestamp --preserve-metadata=identifier,entitlements,flags,runtime \
  --sign "$identity" "$app"

print "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$app" || fail "the application does not verify"
[[ "$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - -)" \
  == '{"com.apple.security.device.audio-input":true}' ]] \
  || fail "the application's entitlements are not the microphone's alone (ADR 0021)"
[[ "$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')" \
  == "$(<"$repository_root/Configuration/DesignatedRequirement.txt")" ]] \
  || fail "the designated requirement is not the one of Configuration/DesignatedRequirement.txt"
for bundle in "$app" "$agent"; do
  [[ "$(codesign -d --verbose=4 "$bundle" 2>&1)" == *"flags="*"(runtime)"* ]] \
    || fail "the hardened runtime is off in $bundle"
done
print "==> $app"
