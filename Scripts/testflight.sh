#!/bin/zsh

# Archives Vibe Companion, the mobile companion's iOS application, and uploads it to TestFlight,
# for the release `v<version>` of the Mac application: the same commit and build number, so that
# a tester knows which Mac the phone goes with. Run by the `testflight` job of
# `.github/workflows/release.yml`, or by hand from the maintainer's Mac.
#
#   Scripts/testflight.sh 1.1.0            archive and upload
#   Scripts/testflight.sh 1.1.0 --dry-run  archive and export, no upload
#
# Signed by Apple: `-allowProvisioningUpdates` with an App Store Connect API key creates the
# distribution certificate and the profiles of the application and of its notification extension
# in the cloud. The key needs the role App Manager (the notarization key's Developer is not enough):
#   ASC_API_KEY_P8                  the key, as base64
#   ASC_API_KEY_ID, ASC_API_ISSUER_ID
# By hand, without them, Xcode's signed-in account does the same.
#
# The team is `VIBE_TEAM_ID`, or `DEVELOPMENT_TEAM` in Configuration/CompanionBase.xcconfig.

set -euo pipefail

readonly repository_root="${0:A:h:h}"

version="${1:-}"
dry_run=0
if [[ "${2:-}" == "--dry-run" ]]; then dry_run=1; fi

fail() {
  print -u2 "testflight: $*"
  exit 1
}

step() {
  print "\n==> $*"
}

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ]] \
  || fail "usage: Scripts/testflight.sh <version> [--dry-run], a version like 1.0.0 or 1.0.0-rc.1"

cd "$repository_root"

team="${VIBE_TEAM_ID:-}"
if [[ -z "$team" ]]; then
  team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' \
    Configuration/CompanionBase.xcconfig | head -1)"
fi
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || fail "no team: set VIBE_TEAM_ID or DEVELOPMENT_TEAM"

# 1. The API key, in a file removed on the way out.
readonly work="$repository_root/build/testflight/$version"
readonly secrets="$(mktemp -d)"
trap 'rm -rf "$secrets"' EXIT
authentication=()
if [[ -n "${ASC_API_KEY_P8:-}" ]]; then
  [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]] \
    || fail "ASC_API_KEY_ID and ASC_API_ISSUER_ID go with ASC_API_KEY_P8"
  print -rn -- "$ASC_API_KEY_P8" | base64 --decode > "$secrets/key.p8"
  authentication=(
    -authenticationKeyPath "$secrets/key.p8"
    -authenticationKeyID "$ASC_API_KEY_ID"
    -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
  )
elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  fail "ASC_API_KEY_P8 is not set"
fi

# 2. The version is the Mac's, without a candidate's suffix: iOS takes three numbers only. The
# build number is release.sh's, which keeps a final above its candidate.
readonly marketing_version="${version%%-*}"
commits="$(git rev-list --count HEAD)"
if [[ "$version" == *-* ]]; then
  readonly build_number="$commits"
else
  readonly build_number="$commits.1"
fi
step "Vibe Companion $marketing_version ($build_number)"
rm -rf "$work"
mkdir -p "$work"

# 3. Archive, signed for distribution by the team, in CloudKit's production environment.
step "Archiving"
xcodebuild \
  -project VibeManager.xcodeproj \
  -scheme VibeCompanion \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$work/Vibe Companion.xcarchive" \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates \
  "${authentication[@]}" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  DEVELOPMENT_TEAM="$team" \
  VIBE_CLOUDKIT_ENVIRONMENT=Production \
  VIBE_APS_ENVIRONMENT=production \
  archive

# 4. Export for App Store Connect: uploaded, unless a dry run keeps the .ipa here.
step "Exporting"
export_options="$work/ExportOptions.plist"
cp Configuration/TestFlightExportOptions.plist "$export_options"
plutil -replace teamID -string "$team" "$export_options"
if (( dry_run )); then
  plutil -replace destination -string export "$export_options"
fi
xcodebuild -exportArchive \
  -archivePath "$work/Vibe Companion.xcarchive" \
  -exportPath "$work/export" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates \
  "${authentication[@]}"

if (( dry_run )); then
  step "Dry run: the build is in $work/export, not uploaded"
else
  step "Uploaded: TestFlight offers it to the testers once App Store Connect has processed it"
fi
