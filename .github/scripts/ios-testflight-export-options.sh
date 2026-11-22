#!/usr/bin/env bash
# Write the export options for one TestFlight export: a copy of
# ios/Config/ExportOptions-TestFlight.plist with the team ID added.
#
# Usage: ios-testflight-export-options.sh <output-plist> <team-id>
#
# Fails if the template no longer describes an internal-only App Store
# Connect export with automatic (cloud-managed) signing.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <output-plist> <team-id>" >&2
  exit 64
fi

output=$1
team_id=$2
if [[ ! $team_id =~ ^[A-Z0-9]{10}$ ]]; then
  echo "::error::The team ID must be 10 uppercase letters and digits, got '$team_id'."
  exit 64
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cp "$repo_root/ios/Config/ExportOptions-TestFlight.plist" "$output"
plutil -replace teamID -string "$team_id" "$output"
plutil -lint "$output"

expect() {
  local key=$1 expected=$2 actual
  actual=$(plutil -extract "$key" raw -o - "$output" 2> /dev/null || echo "(missing)")
  if [ "$actual" != "$expected" ]; then
    echo "::error::Export option $key is '$actual', expected '$expected'."
    exit 1
  fi
}
expect method app-store-connect
expect destination export
expect signingStyle automatic
expect testFlightInternalTestingOnly true
expect manageAppVersionAndBuildNumber false
expect teamID "$team_id"

plutil -p "$output"
