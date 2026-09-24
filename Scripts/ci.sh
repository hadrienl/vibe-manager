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
# Validate package sources with warnings promoted to errors here. Do not pass the equivalent
# build setting globally to xcodebuild: Xcode 16.4 suppresses warnings for package dependencies,
# and combining that inherited flag with warnings-as-errors makes the compiler reject both.
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
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "Building the macOS application in Release"
# Whole-module optimization, -O and dead stripping are otherwise first compiled on the day of a
# release. Unsigned here: signing and notarization are `Scripts/release.sh`'s, on the maintainer's
# Mac.
xcodebuild \
  -project VibeManager.xcodeproj \
  -scheme VibeManager \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$source_packages_path" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build
