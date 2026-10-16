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
# App ID (eu.hadrien.VibeManager.CompanionAgent), with iCloud (CloudKit, iCloud.eu.hadrien.VibeManager.Debug)
# and Push Notifications. Xcode makes it when its account can (Settings → Accounts, signed in, and
# a role allowed to); otherwise it is made in the portal, installed, and named here.
#
# CloudKit in Production: a Developer ID profile allows nothing else. The POC's container,
# iCloud.eu.hadrien.VibeManager.Debug, has its schema deployed there for this trial; the real one
# stays untouched. The iOS application must be built for Production too to see the same records.
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
  VIBE_CLOUDKIT_ENVIRONMENT=Production \
  VIBE_APS_ENVIRONMENT=production \
  archive | grep -E '(error|warning):|\*\* ARCHIVE' || true
[[ -d "$archive" ]] || fail "no archive was made"
rm -rf "$work/derived"

print "==> Exporting with $identity"
readonly export_options="$work/ExportOptions.plist"
plutil -create xml1 "$export_options"
plutil -insert method -string developer-id "$export_options"
plutil -insert teamID -string "$team" "$export_options"
plutil -insert destination -string export "$export_options"
if [[ -n "${VIBE_AGENT_PROFILE:-}" ]]; then
  plutil -insert signingStyle -string manual "$export_options"
  plutil -insert signingCertificate -string "$identity" "$export_options"
  plutil -insert provisioningProfiles -dictionary "$export_options"
  plutil -insert "provisioningProfiles.${agent_identifier//./\\.}" -string "$VIBE_AGENT_PROFILE" \
    "$export_options"
else
  plutil -insert signingStyle -string automatic "$export_options"
fi
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" \
  -exportOptionsPlist "$export_options" -allowProvisioningUpdates \
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

# A Developer ID profile allows CloudKit's Production alone, and the pushes' production: the agent
# is left as the export signed it, which says so.
readonly agent_entitlements="$(codesign -d --entitlements - --xml "$agent" 2>/dev/null \
  | plutil -convert json -o - -)"
[[ "$agent_entitlements" == *'"com.apple.developer.icloud-container-environment":"Production"'* ]] \
  || fail "the agent is not signed for CloudKit's Production: $agent_entitlements"
print "==> Agent: CloudKit Production"

# The localized names win over Info.plist's: every one of them is replaced. Then the application is
# sealed again, as itself — the agent inside keeps its own signature and profile.
for plist in "$app/Contents/Info.plist" "$app"/Contents/Resources/*.lproj/InfoPlist.strings(N); do
  plutil -replace CFBundleDisplayName -string "$name" "$plist"
  plutil -replace CFBundleName -string "$name" "$plist"
done
# The requirement named as release.sh expects it: the export's own leaves out the Developer ID leaf.
codesign --force --timestamp --preserve-metadata=identifier,entitlements,flags,runtime \
  --requirements "=designated => $(<"$repository_root/Configuration/DesignatedRequirement.txt")" \
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
