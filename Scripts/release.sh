#!/bin/zsh

# Builds, signs, notarizes and packages a release of Vibe Manager, then drafts it on GitHub
# (ADR 0021). Two places run it:
#
# - **The release workflow**, `.github/workflows/release.yml`, when a tag `v<version>` is pushed.
#   The tag must already be on `main`. The certificate and the notarization key come from the
#   secrets of the protected `release` environment, go to a temporary keychain and files, and are
#   deleted when the script ends, whatever the outcome.
# - **The maintainer's Mac**, by hand, as a fallback: from `main`, before any tag exists, with the
#   certificate in the login keychain and `xcrun notarytool store-credentials vibe-manager-notary`
#   done once. The tag is created when the draft is published.
#
#   Scripts/release.sh 1.0.0            the whole release, up to a draft on GitHub Releases
#   Scripts/release.sh 1.0.0 --dry-run  everything but notarization and the draft
#
# In the workflow (`GITHUB_ACTIONS=true`), it reads:
#   DEVELOPER_ID_CERTIFICATE_P12        the certificate and its private key, as base64
#   DEVELOPER_ID_CERTIFICATE_PASSWORD   the password of that .p12
#   NOTARY_API_KEY_P8                   an App Store Connect API key (role Developer), as base64
#   NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID
#   SPARKLE_ED_PRIVATE_KEY              the EdDSA key updates are signed with (#92), as
#                                       `generate_keys -x` exports it
#   GH_TOKEN                            to read the CI runs and create the draft
#
# By hand, the EdDSA key is the one `generate_keys` keeps in the login keychain.
#
# The team is `VIBE_TEAM_ID`, or `DEVELOPMENT_TEAM` in Configuration/Local.xcconfig, then Shared.xcconfig.
#
# Every step checks what it produced, and the script stops at the first that fails.

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly notary_profile="vibe-manager-notary"
readonly bundle_identifier="eu.hadrien.VibeManager"
# The Sparkle whose `sign_update` signs the update archive: the version the application embeds,
# pinned by digest like the Apple intermediates. Nothing runs here that cannot be named.
readonly sparkle_version="2.10.0"
readonly sparkle_digest="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"

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

in_ci=0
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then in_ci=1; fi

team="${VIBE_TEAM_ID:-}"
for configuration in Configuration/Local.xcconfig Configuration/Shared.xcconfig; do
  [[ -z "$team" && -f "$configuration" ]] || continue
  team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' \
    "$configuration" | head -1)"
done
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || fail "no team: set VIBE_TEAM_ID or DEVELOPMENT_TEAM"

readonly work="$repository_root/build/release/$version"
readonly archive="$work/Vibe Manager.xcarchive"
readonly exported="$work/export"
readonly app="$exported/Vibe Manager.app"
# No space in the name: GitHub turns spaces of a release asset into dots, and the checksum file
# would name a file nobody downloads.
readonly dmg="$work/VibeManager-$version.dmg"
# What Sparkle downloads and installs (#92, ADR 0033), and what the feed says of it.
readonly update_archive="$work/VibeManager-$version.zip"
readonly appcast_item="$work/VibeManager-$version.appcast.json"

# The workflow's signing material: a keychain of its own, and the notarization key in a file, both
# removed on the way out. On the maintainer's Mac, the login keychain and the stored profile.
secrets="${RUNNER_TEMP:-$repository_root/build}/release-secrets.$$"
keychain=""
saved_keychains=()
notary_credentials=(--keychain-profile "$notary_profile")
# By hand, `sign_update` reads the key from the login keychain.
sparkle_key=()

cleanup() {
  if [[ -n "$keychain" ]]; then
    security list-keychains -d user -s "${saved_keychains[@]}" 2>/dev/null || true
    security delete-keychain "$keychain" 2>/dev/null || true
  fi
  rm -rf "$secrets"
}
trap cleanup EXIT

if (( in_ci )); then
  step "Preparing a temporary keychain"
  for variable in DEVELOPER_ID_CERTIFICATE_P12 DEVELOPER_ID_CERTIFICATE_PASSWORD \
    NOTARY_API_KEY_P8 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID SPARKLE_ED_PRIVATE_KEY GH_TOKEN; do
    [[ -n "${(P)variable:-}" ]] || fail "$variable is not set in the release environment"
  done
  mkdir -p "$secrets"
  chmod 700 "$secrets"
  keychain="$secrets/signing.keychain-db"
  keychain_password="$(uuidgen)"
  saved_keychains=("${(@f)$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//')}")
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  print -rn -- "$DEVELOPER_ID_CERTIFICATE_P12" | base64 --decode > "$secrets/certificate.p12"
  security import "$secrets/certificate.p12" -k "$keychain" \
    -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
  rm -f "$secrets/certificate.p12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" \
    >/dev/null
  # The runner's image may lack the intermediate that issued the certificate, and without it the
  # identity is not valid for signing. Both Developer ID intermediates, pinned by digest: this job
  # holds the certificate, and imports nothing it cannot name.
  for intermediate in DeveloperIDCA:7afc9d01a62f03a2de9637936d4afe68090d2de18d03f29c88cfb0b1ba63587f \
    DeveloperIDG2CA:f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a; do
    name="${intermediate%%:*}"
    curl --fail --silent --show-error --output "$secrets/$name.cer" \
      "https://www.apple.com/certificateauthority/$name.cer"
    [[ "$(shasum -a 256 "$secrets/$name.cer" | cut -d ' ' -f 1)" == "${intermediate#*:}" ]] \
      || fail "the intermediate $name is not the one expected"
    security import "$secrets/$name.cer" -k "$keychain"
  done
  security list-keychains -d user -s "$keychain" "${saved_keychains[@]}"
  print -rn -- "$NOTARY_API_KEY_P8" | base64 --decode > "$secrets/notary.p8"
  notary_credentials=(
    --key "$secrets/notary.p8" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID"
  )
  print -rn -- "$SPARKLE_ED_PRIVATE_KEY" > "$secrets/sparkle.key"
  sparkle_key=(--ed-key-file "$secrets/sparkle.key")
fi

# 1. The tree is what CI tested.
step "Checking the tree"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree is not clean"
git fetch --quiet origin main
if (( in_ci )); then
  # Pushed by the maintainer: the tag names this very commit, and that commit is on main.
  [[ "$(git rev-parse -q --verify "refs/tags/v$version^{commit}" || true)" == "$(git rev-parse HEAD)" ]] \
    || fail "the tag v$version does not name the commit being built"
  git merge-base --is-ancestor HEAD origin/main || fail "the tagged commit is not on main"
else
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "not on main"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || fail "main is not what origin/main is: push or pull first"
  if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    fail "the tag v$version already exists: push it to let the release workflow build it"
  fi
fi
commit="$(git rev-parse HEAD)"
# A tag pushed right after a merge finds the CI of that merge still running, or not yet created:
# wait for the latest run to end rather than fail. Two minutes for it to appear, thirty to end.
ci_waited=0
while true; do
  ci="$(gh run list --commit "$commit" --workflow CI --json conclusion,status \
    --jq '.[0] | if . == null then "" elif .status == "completed" then .conclusion else "running" end' \
    2>/dev/null || true)"
  if [[ "$ci" == "running" ]]; then
    (( ci_waited < 1800 )) || break
  elif [[ -z "$ci" ]]; then
    (( ci_waited < 120 )) || break
  else
    break
  fi
  (( ci_waited == 0 )) && print "Waiting for the CI of $commit to end"
  sleep 20
  (( ci_waited += 20 ))
done
[[ "$ci" == "success" ]] || fail "CI is not green on $commit (found: ${ci:-nothing})"
readonly identity="$(security find-identity -v -p codesigning \
  | sed -n "s/.*\"\(Developer ID Application: .*($team)\)\"/\1/p" | head -1)"
if [[ -z "$identity" ]]; then
  # What is there but not valid, and why: an untrusted chain, an expired certificate, no key.
  security find-identity -p codesigning | sed -n '/Developer ID/p' >&2
  fail "no valid Developer ID Application certificate for team $team in the keychain"
fi

# 2. The version is given to the build, not written into the repository. A final version is built
# from the commit of its last release candidate, so it has the same number of commits: `.1` makes
# it the later of the two, and Sparkle offers it to whoever runs that candidate (#92).
commits="$(git rev-list --count HEAD)"
if [[ "$version" == *-* ]]; then
  readonly build_number="$commits"
else
  readonly build_number="$commits.1"
fi
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
export_options="$work/ExportOptions.plist"
cp Configuration/ExportOptions.plist "$export_options"
plutil -replace teamID -string "$team" "$export_options"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$exported" \
  -exportOptionsPlist "$export_options"
[[ -d "$app" ]] || fail "the export has no application"

# 4. The binary is what a release must be.
step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$app" || fail "the signature does not verify"
# The export signs with an empty dictionary: what matters is that it grants nothing.
entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
if [[ -n "$entitlements" ]]; then
  [[ "$(print -rn -- "$entitlements" | plutil -convert json -o - -)" == "{}" ]] \
    || fail "the application has entitlements, and needs none (ADR 0001)"
fi
# Read whole, then matched: `grep -q` stops at the first match, the writer gets SIGPIPE, and
# `pipefail` turns a pass into a failure.
signature="$(codesign -d --verbose=4 "$app" 2>&1)"
[[ "$signature" == *"flags="*"(runtime)"* ]] || fail "the hardened runtime is off"
requirement="$(codesign -d -r- "$app" 2>&1)"
[[ "$requirement" == *"certificate leaf[subject.OU] = \"$team\""* \
  || "$requirement" == *"certificate leaf[subject.OU] = $team"* ]] \
  || fail "the designated requirement does not name team $team, so an ad hoc binary could pass for the terminal host's peer (security review A6)"
# The same requirement from one version to the next: TCC keys Full Disk Access to it, the host
# requires it of the application, and Sparkle of the update (#92). A change is a reviewed change
# of Configuration/DesignatedRequirement.txt, never an accident of the build.
[[ "$(print -r -- "$requirement" | sed -n 's/^designated => //p')" \
  == "$(<Configuration/DesignatedRequirement.txt)" ]] \
  || fail "the designated requirement is not the one of Configuration/DesignatedRequirement.txt: $requirement"
readonly update_key="$(defaults read "$app/Contents/Info.plist" SUPublicEDKey 2>/dev/null || true)"
[[ -n "$update_key" ]] || (( dry_run )) \
  || fail "the application carries no SUPublicEDKey, and would never update"
[[ "$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier)" == "$bundle_identifier" ]] \
  || fail "unexpected bundle identifier"
[[ "$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)" == "$version" ]] \
  || fail "the bundle does not carry version $version"
[[ -n "$(find "$app" -name mock-agent.sh)" ]] \
  || fail "mock-agent.sh is missing: the smoke test runs against it (security review A8)"
if [[ -n "$(find "$app" -name 'Local.xcconfig')" ]]; then
  fail "a Local.xcconfig was bundled"
fi

notarize() {
  local artifact="$1"
  local submission="$2"
  xcrun notarytool submit "$submission" "${notary_credentials[@]}" --wait \
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

# 6. The update archive: the application as stapled, signed with the EdDSA key, and checked
# against the key the application carries, which is the one Sparkle will check it with.
step "Signing the update archive"
sparkle_tools="$repository_root/build/sparkle-$sparkle_version"
if [[ ! -x "$sparkle_tools/bin/sign_update" ]]; then
  rm -rf "$sparkle_tools"
  mkdir -p "$sparkle_tools"
  curl --fail --silent --show-error --location --output "$sparkle_tools.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
  [[ "$(shasum -a 256 "$sparkle_tools.tar.xz" | cut -d ' ' -f 1)" == "$sparkle_digest" ]] \
    || fail "the Sparkle $sparkle_version archive is not the one expected"
  tar -xf "$sparkle_tools.tar.xz" -C "$sparkle_tools" ./bin/sign_update
  rm -f "$sparkle_tools.tar.xz"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$update_archive"
if ! update_signature="$("$sparkle_tools/bin/sign_update" "${sparkle_key[@]}" -p "$update_archive")"
then
  (( dry_run )) || fail "the update archive could not be signed: no EdDSA key"
  print "Dry run: no EdDSA key, the update archive is left unsigned"
  update_signature=""
fi
if [[ -n "$update_signature" && -n "$update_key" ]]; then
  xcrun swift Scripts/check-update-signature.swift "$update_key" "$update_signature" \
    "$update_archive" || fail "the update archive would be refused by the application"
fi
readonly host_protocol="$(sed -n 's/^ *static let protocolVersion = \([0-9]*\)$/\1/p' \
  Packages/VibeManagerKit/Sources/VibeTerminal/TerminalHostWire.swift)"
[[ "$host_protocol" =~ '^[0-9]+$' ]] || fail "the terminal host's protocol version was not found"
readonly minimum_system="$(defaults read "$app/Contents/Info.plist" LSMinimumSystemVersion)"
# What the feed says of this version, read by Scripts/publish-appcast.sh once the release is
# published: the Pages workflow holds no key, everything signed is signed here.
print -r -- "{\"version\":\"$version\",\"build\":\"$build_number\",\"archive\":\"${update_archive:t}\",\"length\":$(stat -f %z "$update_archive"),\"edSignature\":\"$update_signature\",\"minimumSystemVersion\":\"$minimum_system\",\"hostProtocol\":$host_protocol}" \
  > "$appcast_item"
plutil -convert json -o /dev/null "$appcast_item" || fail "the appcast item is not valid JSON"
cat "$appcast_item"

# 7. The disk image: built by hdiutil, signed, notarized and stapled in turn.
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

# 8. The checksum, and a draft: published only once the checklist is ticked.
step "Checksum"
(cd "$work" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
cat "$dmg.sha256"

if (( dry_run )); then
  step "Dry run: no draft created. The image is $dmg"
  exit 0
fi

step "Drafting the release"
release_options=(--draft --title "Vibe Manager $version" --generate-notes)
if (( in_ci )); then
  release_options+=(--verify-tag)
else
  release_options+=(--target "$commit")
fi
# A version with a suffix — 1.0.0-rc.1 — is a release candidate.
if [[ "$version" == *-* ]]; then release_options+=(--prerelease); fi
gh release create "v$version" "$dmg" "$dmg.sha256" "$update_archive" "$appcast_item" \
  "${release_options[@]}"

print "\nDraft v$version created. Work through docs/release-checklist.md, then publish it."
