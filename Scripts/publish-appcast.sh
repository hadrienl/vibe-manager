#!/bin/zsh

# Builds the site that GitHub Pages serves: the landing page rendered from `site/`, and the Sparkle
# feed `appcast.xml` computed beside it from the published releases (ADR 0033). Two places run it:
#
# - **The Appcast workflow**, `.github/workflows/appcast.yml`, when a release is published,
#   unpublished, edited or deleted, and when `site/` changes on `main`. It uploads the folder to
#   Pages.
# - **The maintainer's Mac**, to see the feed the workflow would publish, without publishing it.
#
#   Scripts/publish-appcast.sh <folder>   the site in <folder>, which is created if needed
#
# It reads:
#   GH_TOKEN             to read the releases (optional on a Mac where `gh auth login` was done)
#   GITHUB_REPOSITORY    the repository, `hadrienl/vibe-manager` by default
#
# The feed is recomputed in full every time. A draft never enters it: its assets are not even
# downloaded. No secret is needed: each release carries its EdDSA signature in its
# `VibeManager-<version>.appcast.json`, written by Scripts/release.sh.

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly repository="${GITHUB_REPOSITORY:-hadrienl/vibe-manager}"

fail() {
  print -u2 "publish-appcast: $*"
  exit 1
}

(( $# == 1 )) || fail "usage: Scripts/publish-appcast.sh <folder>"
command -v gh >/dev/null || fail "gh is required"
command -v node >/dev/null || fail "node is required"

mkdir -p "$1"
readonly site="${1:A}"
readonly work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/items"

echo "Reading the releases of $repository"
gh api --paginate --slurp "repos/$repository/releases" > "$work/releases.json"

# The landing page, one folder per language, its changelog rendered from the same releases.
echo "Building the site"
node "$repository_root/site/build.mjs" "$site" "$work/releases.json"

# The tag of every published release that has an appcast item; the tool decides the rest.
tags=("${(@f)$(
  gh api --paginate "repos/$repository/releases" \
    --jq '.[] | select(.draft == false)
      | select(any(.assets[]; .name | test("^VibeManager-.*\\.appcast\\.json$")))
      | .tag_name'
)}")
for tag in "${tags[@]}"; do
  [[ -n "$tag" ]] || continue
  echo "Downloading the appcast item of $tag"
  gh release download "$tag" --repo "$repository" \
    --pattern 'VibeManager-*.appcast.json' --output "$work/items/$tag.json"
done

echo "Generating the feed"
swift run --package-path "$repository_root/Packages/ReleaseTools" appcast \
  --releases "$work/releases.json" --items "$work/items" --output "$site/appcast.xml"
