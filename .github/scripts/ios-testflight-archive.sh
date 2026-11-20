#!/usr/bin/env bash
# Archive the FreeFlow iOS app for devices with an ad-hoc signature.
#
# Usage: ios-testflight-archive.sh <output-dir> <team-id> <bundle-id-prefix> <build-number>
#
# Writes <output-dir>/FreeFlow.xcarchive, using <output-dir>/DerivedData.
#
# The archive is signed ad hoc ("-"), so it needs no certificate or
# provisioning profile and creates nothing on the developer account.
# Automatic signing would create a new Apple Development certificate on
# every fresh CI runner. The ad-hoc signature still carries the App Group and
# keychain entitlements for `xcodebuild -exportArchive` to re-sign with.
# CODE_SIGNING_ALLOWED=NO would drop them from the keyboard extension.
#
# Both jobs in .github/workflows/ios-testflight.yml run this script, so the
# dry run archives with the same command as the upload. Never add
# PRODUCT_BUNDLE_IDENTIFIER here: command-line settings apply to every
# target, which would give the app and the keyboard the same ID.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <output-dir> <team-id> <bundle-id-prefix> <build-number>" >&2
  exit 64
fi

output_dir=$1
team_id=$2
bundle_id_prefix=$3
build_number=$4

if [[ ! $team_id =~ ^[A-Z0-9]{10}$ ]]; then
  echo "::error::The team ID must be 10 uppercase letters and digits, got '$team_id'."
  exit 64
fi
if [[ ! $bundle_id_prefix =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "::error::The bundle ID prefix must look like com.example.app, got '$bundle_id_prefix'."
  exit 64
fi
if [[ ! $build_number =~ ^[0-9]{1,9}(\.[0-9]{1,9}){0,2}$ ]]; then
  echo "::error::The build number must be one to three period-separated integers, got '$build_number'."
  exit 64
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
project="$repo_root/ios/FreeFlow.xcodeproj"
mkdir -p "$output_dir"

settings=(
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY=-
  AD_HOC_CODE_SIGNING_ALLOWED=YES
  DEVELOPMENT_TEAM="$team_id"
  FREEFLOW_BUNDLE_ID_PREFIX="$bundle_id_prefix"
  # Ad-hoc signing has no provisioning profile to take the team prefix from,
  # so pass it for the keychain access group. See ios/Config/FreeFlow.xcconfig.
  FREEFLOW_KEYCHAIN_GROUP_PREFIX="$team_id."
  CURRENT_PROJECT_VERSION="$build_number"
)

echo "::group::Resolved Release build settings"
xcodebuild -showBuildSettings -json \
  -project "$project" \
  -scheme FreeFlow \
  -configuration Release \
  -destination "generic/platform=iOS" \
  "${settings[@]}" \
  | jq '.[] | {target, settings: (.buildSettings | {
      PRODUCT_BUNDLE_IDENTIFIER, PLATFORM_NAME, ARCHS, MARKETING_VERSION,
      CURRENT_PROJECT_VERSION, CODE_SIGN_STYLE, CODE_SIGN_IDENTITY,
      AD_HOC_CODE_SIGNING_ALLOWED, DEVELOPMENT_TEAM, AppIdentifierPrefix,
      FREEFLOW_BUNDLE_ID_PREFIX, FREEFLOW_KEYCHAIN_GROUP_PREFIX,
      CODE_SIGN_ENTITLEMENTS, SWIFT_ACTIVE_COMPILATION_CONDITIONS})}' \
  || echo "::warning::Could not show the resolved build settings."
echo "::endgroup::"

xcodebuild archive \
  -project "$project" \
  -scheme FreeFlow \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$output_dir/FreeFlow.xcarchive" \
  -derivedDataPath "$output_dir/DerivedData" \
  "${settings[@]}"
