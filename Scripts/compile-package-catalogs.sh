#!/bin/zsh

# Compiles each string catalog of the package into the resource bundle `swift build` made for it.
#
# The SwiftPM of Xcode 16.4, which CI uses, copies a target's resources without compiling its
# `Localizable.xcstrings`: its bundles have no `en.lproj` nor `fr.lproj`, and every translated or
# plural string reads as its key in the tests. Recent SwiftPMs compile them already, and this only
# writes the same tables again. The application is built by Xcode, which always compiles them.
# Run between `swift build --build-tests` and `swift test --skip-build`, which would copy the
# resources again.

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly package_path="$repository_root/Packages/VibeManagerKit"
readonly build_path="$package_path/.build"

compiled=0
for catalog in "$package_path"/Sources/*/Localizable.xcstrings(N); do
  target="${catalog:h:t}"
  for bundle in "$build_path"/**/VibeManagerKit_"$target".bundle(N/); do
    # A macOS bundle keeps its resources in Contents/Resources; SwiftPM's flat one, at its root.
    resources="$bundle"
    [[ -d "$bundle/Contents/Resources" ]] && resources="$bundle/Contents/Resources"
    xcrun xcstringstool compile "$catalog" --output-directory "$resources" >/dev/null
    compiled=$((compiled + 1))
  done
done

if (( compiled == 0 )); then
  echo "No resource bundle found to compile the catalogs into: build the package first." >&2
  exit 1
fi
echo "Compiled the package's catalogs into $compiled resource bundle(s)."
