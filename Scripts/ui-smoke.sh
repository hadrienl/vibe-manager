#!/bin/zsh

# The interface smoke test (`UITests/VibeManagerUITests`), against a Debug build signed ad hoc, or
# with the team of `Configuration/Local.xcconfig` when there is one. Run by the `ui-smoke` job and by
# the release checklist; it needs a logged-in graphical session.

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly derived_data_path="${DERIVED_DATA_PATH:-$repository_root/DerivedData/UISmoke}"
# Screenshots and the accessibility tree of a failure: the `ui-smoke` job uploads it.
readonly result_bundle_path="$derived_data_path/UISmoke.xcresult"

cd "$repository_root"
rm -rf "$result_bundle_path"

xcodebuild \
  -project VibeManager.xcodeproj \
  -scheme VibeManager \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data_path" \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY=- \
  -resultBundlePath "$result_bundle_path" \
  test \
  -only-testing:VibeManagerUITests
