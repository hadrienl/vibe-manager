#!/bin/zsh

# Builds, signs, notarizes and packages a release of Vibe Manager, then drafts it on GitHub
# (ADR 0021). Run on the maintainer's Mac, never in CI: the Developer ID certificate and the
# notarization credentials stay in its keychain.
#
#   Scripts/release.sh 1.0.0            the whole release, up to a draft on GitHub Releases
#   Scripts/release.sh 1.0.0 --dry-run  everything but notarization and the draft
#
# Before the first release:
#   - a "Developer ID Application" certificate of the team in the login keychain;
#   - `xcrun notarytool store-credentials vibe-manager-notary` — the credentials go to the
#     keychain, never to a file or an environment variable;
#   - `gh auth login`.
#
# The team is `VIBE_TEAM_ID`, or `DEVELOPMENT_TEAM` in Configuration/Local.xcconfig.
#
# Every step checks what it produced, and the script stops at the first that fails.

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly notary_profile="vibe-manager-notary"
readonly bundle_identifier="com.hadrienl.VibeManager"

version="${1:-}"
dry_run=0
if [[ "${2:-}" == "--dry-run" ]]; then dry_run=1; fi

fail() {
  print -u2 "release: $*"
  exit 1
}

step() {
  print "\n==> $*"
}

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ]] \
  || fail "usage: Scripts/release.sh <version> [--dry-run], a version like 1.0.0 or 1.0.0-rc.1"

cd "$repository_root"

team="${VIBE_TEAM_ID:-}"
if [[ -z "$team" && -f Configuration/Local.xcconfig ]]; then
  team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' \
    Configuration/Local.xcconfig | head -1)"
fi
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || fail "no team: set VIBE_TEAM_ID or DEVELOPMENT_TEAM"

readonly work="$repository_root/build/release/$version"
readonly archive="$work/Vibe Manager.xcarchive"
readonly exported="$work/export"
readonly app="$exported/Vibe Manager.app"
readonly dmg="$work/Vibe Manager $version.dmg"

# 1. The tree is what CI tested.
step "Checking the tree"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree is not clean"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "not on main"
git fetch --quiet origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
  || fail "main is not what origin/main is: push or pull first"
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  fail "the tag v$version already exists"
fi
commit="$(git rev-parse HEAD)"
ci="$(gh run list --commit "$commit" --workflow CI --json conclusion,status \
  --jq '[.[] | select(.status == "completed")][0].conclusion' 2>/dev/null || true)"
[[ "$ci" == "success" ]] || fail "CI is not green on $commit (found: ${ci:-nothing})"
readonly identity="$(security find-identity -v -p codesigning \
  | sed -n "s/.*\"\(Developer ID Application: .*($team)\)\"/\1/p" | head -1)"
[[ -n "$identity" ]] || fail "no Developer ID Application certificate for team $team in the keychain"

# 2. The version is given to the build, not written into the repository.
readonly build_number="$(git rev-list --count HEAD)"
step "Version $version ($build_number)"
rm -rf "$work"
mkdir -p "$work"

# 3. Archive and export, signed with the Developer ID of the team.
step "Archiving"
xcodebuild \
  -project VibeManager.xcodeproj \
  -scheme VibeManager \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -skipPackagePluginValidation \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  DEVELOPMENT_TEAM="$team" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive

step "Exporting"
options="$work/ExportOptions.plist"
cp Configuration/ExportOptions.plist "$options"
plutil -replace teamID -string "$team" "$options"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$exported" \
  -exportOptionsPlist "$options"
[[ -d "$app" ]] || fail "the export has no application"

# 4. The binary is what a release must be.
step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$app" || fail "the signature does not verify"
entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null || true)"
[[ -z "$entitlements" ]] || fail "the application has entitlements, and needs none (ADR 0001)"
codesign -d --verbose=4 "$app" 2>&1 | grep -q 'flags=.*runtime' \
  || fail "the hardened runtime is off"
requirement="$(codesign -d -r- "$app" 2>&1)"
[[ "$requirement" == *"certificate leaf[subject.OU] = \"$team\""* \
  || "$requirement" == *"certificate leaf[subject.OU] = $team"* ]] \
  || fail "the designated requirement does not name team $team, so an ad hoc binary could pass for the terminal host's peer (security review A6)"
[[ "$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier)" == "$bundle_identifier" ]] \
  || fail "unexpected bundle identifier"
[[ "$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)" == "$version" ]] \
  || fail "the bundle does not carry version $version"
find "$app" -name mock-agent.sh | grep -q . \
  || fail "mock-agent.sh is missing: the smoke test runs against it (security review A8)"
if find "$app" -name 'Local.xcconfig' | grep -q .; then
  fail "a Local.xcconfig was bundled"
fi

notarize() {
  local artifact="$1"
  local submission="$2"
  xcrun notarytool submit "$submission" --keychain-profile "$notary_profile" --wait \
    --output-format json > "$work/notary.json"
  [[ "$(plutil -extract status raw "$work/notary.json")" == "Accepted" ]] \
    || fail "notarization of $(basename "$artifact") was not accepted: see $work/notary.json"
  xcrun stapler staple "$artifact"
  xcrun stapler validate "$artifact"
}

# 5. The application, notarized and stapled.
if (( dry_run )); then
  step "Dry run: notarization skipped"
else
  step "Notarizing the application"
  ditto -c -k --keepParent "$app" "$work/Vibe Manager.zip"
  notarize "$app" "$work/Vibe Manager.zip"
  spctl -a -vvv -t exec "$app" || fail "Gatekeeper rejects the application"
fi

# 6. The disk image: built by hdiutil, signed, notarized and stapled in turn.
step "Building the disk image"
staging="$work/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Vibe Manager.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Vibe Manager" -srcfolder "$staging" -format UDZO -ov "$dmg"
codesign --sign "$identity" --timestamp --identifier "$bundle_identifier.dmg" "$dmg"
codesign --verify --verbose=2 "$dmg" || fail "the disk image signature does not verify"
if (( ! dry_run )); then
  step "Notarizing the disk image"
  notarize "$dmg" "$dmg"
  spctl -a -vvv -t open --context context:primary-signature "$dmg" \
    || fail "Gatekeeper rejects the disk image"
fi

# 7. The checksum, and a draft: published only once the checklist is ticked.
step "Checksum"
(cd "$work" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
cat "$dmg.sha256"

if (( dry_run )); then
  step "Dry run: no draft created. The image is $dmg"
  exit 0
fi

step "Drafting the release"
release_options=(--draft --target "$commit" --title "Vibe Manager $version" --generate-notes)
# A version with a suffix — 1.0.0-rc.1 — is a release candidate.
if [[ "$version" == *-* ]]; then release_options+=(--prerelease); fi
gh release create "v$version" "$dmg" "$dmg.sha256" "${release_options[@]}"

print "\nDraft v$version created. Work through docs/release-checklist.md, then publish it."
