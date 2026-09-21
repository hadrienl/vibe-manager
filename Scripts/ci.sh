#!/bin/zsh

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly package_path="$repository_root/Packages/VibeManagerKit"
readonly derived_data_path="${DERIVED_DATA_PATH:-$repository_root/DerivedData/CI}"
readonly module_cache_path="$repository_root/.build/ModuleCache"
readonly source_packages_path="$derived_data_path/SourcePackages"

export CLANG_MODULE_CACHE_PATH="$module_cache_path"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_path"

cd "$repository_root"

echo "Checking Swift formatting"
xcrun swift-format lint --recursive \
  App \
  Packages/VibeManagerKit/Sources \
  Packages/VibeManagerKit/Tests \
  Packages/VibeManagerKit/Package.swift

echo "Running package tests"
swift test \
  --package-path "$package_path" \
  -Xswiftc -warnings-as-errors

echo "Building the macOS application"
xcodebuild \
  -project VibeManager.xcodeproj \
  -scheme VibeManager \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$source_packages_path" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  build
