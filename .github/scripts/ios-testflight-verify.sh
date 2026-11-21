#!/usr/bin/env bash
# Check the identifiers and signed entitlements of a FreeFlow iOS build.
#
# Usage: ios-testflight-verify.sh archive|ipa <FreeFlow.app> <team-id> <bundle-id-prefix> <build-number>
#
#   archive  the ad-hoc signed app in a .xcarchive (Products/Applications)
#   ipa      the App Store signed app unzipped from an exported .ipa (Payload)
#
# Both modes fail unless the app and its keyboard extension have:
#   - bundle IDs <prefix> and <prefix>.keyboard, build number <build-number>,
#     and the same version string
#   - FreeFlowAppGroupIdentifier group.<prefix> and FreeFlowKeychainAccessGroup
#     <team-id>.<prefix>.shared in their Info.plists
#   - group.<prefix> in com.apple.security.application-groups and
#     <team-id>.<prefix>.shared in keychain-access-groups, in the signature
#   - no FAKETEAMID in an Info.plist or a keychain access group
#   - ITSAppUsesNonExemptEncryption false (app only)
# ipa mode also requires, for both bundles:
#   - a signature that isn't ad hoc, from team <team-id>
#   - get-task-allow false, application-identifier <team-id>.<bundle ID>,
#     com.apple.developer.team-identifier <team-id>, and no FAKETEAMID
#     anywhere in the signed entitlements
#   - an embedded App Store provisioning profile (no device list) from
#     <team-id> that allows the App Group and the keychain group
#
# It prints identifiers and entitlements only, never certificate or team
# names: the logs of a public repository are public.
set -euo pipefail

if [ "$#" -ne 5 ] || { [ "$1" != archive ] && [ "$1" != ipa ]; }; then
  echo "usage: $0 archive|ipa <FreeFlow.app> <team-id> <bundle-id-prefix> <build-number>" >&2
  exit 64
fi

mode=$1
app=$2
team_id=$3
bundle_id_prefix=$4
build_number=$5
appex="$app/PlugIns/FreeFlowKeyboard.appex"

for bundle in "$app" "$appex"; do
  if [ ! -d "$bundle" ]; then
    echo "::error::Missing bundle: $bundle"
    exit 1
  fi
done

work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ios-testflight-verify.XXXXXX")
for name in app appex; do
  if [ "$name" = app ]; then bundle=$app; else bundle=$appex; fi
  if ! codesign -d --entitlements - --xml "$bundle" > "$work/$name.entitlements.plist" 2> "$work/$name.entitlements.err"; then
    cat "$work/$name.entitlements.err" >&2
    echo "::error::Could not read the signed entitlements of $bundle"
    exit 1
  fi
  # Identifier, format, team, and whether the signature is ad hoc. This file
  # is parsed, not printed; only higher verbosity adds certificate names.
  codesign -dv "$bundle" 2> "$work/$name.codesign.txt" || true
  if ! codesign --verify --strict "$bundle" 2> "$work/$name.verify.txt"; then
    cat "$work/$name.verify.txt" >&2
    echo "::error::The code signature of $bundle does not verify"
    exit 1
  fi
  if [ -f "$bundle/embedded.mobileprovision" ]; then
    if ! security cms -D -i "$bundle/embedded.mobileprovision" > "$work/$name.profile.plist" 2> /dev/null; then
      echo "::error::Could not decode $bundle/embedded.mobileprovision"
      exit 1
    fi
  fi
done

echo "::group::Nested code in $(basename "$app")"
(cd "$app" && find . \( -name '*.appex' -o -name '*.framework' -o -name '*.dylib' \) -print | LC_ALL=C sort)
echo "::endgroup::"

python3 - "$mode" "$work" "$app" "$team_id" "$bundle_id_prefix" "$build_number" <<'PY'
import fnmatch
import os
import plistlib
import sys

mode, work, app, team_id, prefix, build_number = sys.argv[1:7]
bundles = [
    ("app", app, prefix),
    ("appex", os.path.join(app, "PlugIns", "FreeFlowKeyboard.appex"), prefix + ".keyboard"),
]
app_group = "group." + prefix
keychain_group = team_id + "." + prefix + ".shared"
failures = []
summary = []
versions = {}


def check(condition, message):
    if not condition:
        failures.append(message)
    return condition


def allows(patterns, value):
    """Whether a profile's entitlement value list permits value ('TEAM.*' style wildcards)."""
    if isinstance(patterns, str):
        patterns = [patterns]
    return any(fnmatch.fnmatchcase(value, pattern) for pattern in patterns or [])


for name, path, bundle_id in bundles:
    label = os.path.basename(path)
    with open(os.path.join(path, "Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    with open(os.path.join(work, name + ".entitlements.plist"), "rb") as handle:
        raw_entitlements = handle.read()
    entitlements = plistlib.loads(raw_entitlements) if raw_entitlements.strip() else {}
    codesign = {}
    with open(os.path.join(work, name + ".codesign.txt"), encoding="utf-8", errors="replace") as handle:
        for line in handle:
            key, _, value = line.rstrip("\n").partition("=")
            codesign.setdefault(key, value)
    profile = None
    profile_path = os.path.join(work, name + ".profile.plist")
    if os.path.exists(profile_path):
        with open(profile_path, "rb") as handle:
            profile = plistlib.load(handle)

    print(f"::group::{label}: Info.plist identifiers")
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
                "FreeFlowAppGroupIdentifier", "FreeFlowKeychainAccessGroup",
                "ITSAppUsesNonExemptEncryption", "MinimumOSVersion", "DTPlatformName", "DTSDKName"):
        if key in info:
            print(f"{key} = {info[key]!r}")
    print("::endgroup::")
    print(f"::group::{label}: signed entitlements")
    print(raw_entitlements.decode("utf-8", "replace").strip() or "(none)")
    print("::endgroup::")
    print(f"::group::{label}: signature")
    for key in ("Identifier", "Format", "TeamIdentifier", "Signature"):
        if key in codesign:
            print(f"{key}={codesign[key]}")
    print("embedded.mobileprovision: " + ("present" if profile is not None else "none"))
    if profile is not None:
        profile_entitlements = profile.get("Entitlements", {})
        print(f"profile Name={profile.get('Name')!r} Platform={profile.get('Platform')!r} "
              f"ExpirationDate={profile.get('ExpirationDate')} "
              f"devices={len(profile.get('ProvisionedDevices', []))} "
              f"ProvisionsAllDevices={profile.get('ProvisionsAllDevices', False)!r}")
        for key in ("application-identifier", "com.apple.security.application-groups",
                    "keychain-access-groups", "get-task-allow", "beta-reports-active"):
            print(f"profile entitlement {key} = {profile_entitlements.get(key)!r}")
    print("::endgroup::")

    versions[label] = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
    check(info.get("CFBundleIdentifier") == bundle_id,
          f"{label}: CFBundleIdentifier is {info.get('CFBundleIdentifier')!r}, expected {bundle_id!r}")
    check(info.get("CFBundleVersion") == build_number,
          f"{label}: CFBundleVersion is {info.get('CFBundleVersion')!r}, expected {build_number!r}")
    check(bool(info.get("CFBundleShortVersionString")),
          f"{label}: CFBundleShortVersionString is missing")
    check(info.get("FreeFlowAppGroupIdentifier") == app_group,
          f"{label}: FreeFlowAppGroupIdentifier is {info.get('FreeFlowAppGroupIdentifier')!r}, expected {app_group!r}")
    check(info.get("FreeFlowKeychainAccessGroup") == keychain_group,
          f"{label}: FreeFlowKeychainAccessGroup is {info.get('FreeFlowKeychainAccessGroup')!r}, expected {keychain_group!r}")
    check("FAKETEAMID" not in repr(info), f"{label}: Info.plist contains FAKETEAMID")
    if name == "app":
        check(info.get("ITSAppUsesNonExemptEncryption") is False,
              f"{label}: ITSAppUsesNonExemptEncryption is {info.get('ITSAppUsesNonExemptEncryption')!r}, expected False")
    else:
        point = (info.get("NSExtension") or {}).get("NSExtensionPointIdentifier")
        check(point == "com.apple.keyboard-service",
              f"{label}: NSExtensionPointIdentifier is {point!r}, expected 'com.apple.keyboard-service'")

    groups = entitlements.get("com.apple.security.application-groups", [])
    keychain_groups = entitlements.get("keychain-access-groups", [])
    check(app_group in groups,
          f"{label}: com.apple.security.application-groups is {groups!r}, expected it to contain {app_group!r}")
    check(keychain_group in keychain_groups,
          f"{label}: keychain-access-groups is {keychain_groups!r}, expected it to contain {keychain_group!r}")
    check(not any("FAKETEAMID" in group for group in keychain_groups),
          f"{label}: keychain-access-groups contains FAKETEAMID: {keychain_groups!r}")

    application_identifier = entitlements.get("application-identifier")
    get_task_allow = entitlements.get("get-task-allow")
    if mode == "ipa":
        check(b"FAKETEAMID" not in raw_entitlements, f"{label}: the signed entitlements contain FAKETEAMID")
        check(get_task_allow is not True, f"{label}: get-task-allow is true; App Store builds must not be debuggable")
        check(application_identifier == f"{team_id}.{bundle_id}",
              f"{label}: application-identifier is {application_identifier!r}, expected '{team_id}.{bundle_id}'")
        check(entitlements.get("com.apple.developer.team-identifier") == team_id,
              f"{label}: com.apple.developer.team-identifier is "
              f"{entitlements.get('com.apple.developer.team-identifier')!r}, expected {team_id!r}")
        check(codesign.get("Signature") != "adhoc", f"{label}: the signature is still ad hoc")
        check(codesign.get("TeamIdentifier") == team_id,
              f"{label}: the signature's TeamIdentifier is {codesign.get('TeamIdentifier')!r}, expected {team_id!r}")
        if entitlements.get("beta-reports-active") is not True:
            print(f"::warning::{label}: beta-reports-active is {entitlements.get('beta-reports-active')!r}; "
                  "App Store profiles normally set it to true.")
        if check(profile is not None, f"{label}: no embedded.mobileprovision"):
            profile_entitlements = profile.get("Entitlements", {})
            check(not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"),
                  f"{label}: the embedded profile is not an App Store profile (it lists devices)")
            check(team_id in profile.get("TeamIdentifier", []),
                  f"{label}: the embedded profile belongs to team {profile.get('TeamIdentifier')!r}, expected {team_id!r}")
            check(allows(profile_entitlements.get("com.apple.security.application-groups"), app_group),
                  f"{label}: the embedded profile does not allow {app_group!r}. Assign the App Group to "
                  f"the {bundle_id} App ID (ios/TESTFLIGHT.md).")
            check(allows(profile_entitlements.get("keychain-access-groups"), keychain_group),
                  f"{label}: the embedded profile does not allow keychain group {keychain_group!r}")
    elif application_identifier and "FAKETEAMID" in application_identifier:
        print(f"::notice::{label}: the ad-hoc archive's application-identifier is {application_identifier!r}. "
              "The App Store export replaces it with the provisioning profile's value; ipa mode checks that.")

    summary.append((label, info.get("CFBundleIdentifier"), info.get("CFBundleVersion"),
                    ", ".join(groups) or "-", ", ".join(keychain_groups) or "-",
                    application_identifier or "-", repr(get_task_allow)))

check(len(set(versions.values())) == 1,
      f"the app and keyboard versions differ: {versions!r}; App Store Connect expects them to match")


def leaves(value, path=""):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from leaves(child, f"{path}.{key}" if path else str(key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from leaves(child, f"{path}[{index}]")
    else:
        yield path, value


if mode == "ipa":
    # Information only. Apple doesn't document how an export made with
    # testFlightInternalTestingOnly marks the IPA, so show any plist entry that
    # mentions it. App Store Connect shows the result under the build number.
    root = os.path.dirname(os.path.dirname(app))
    print("::group::IPA contents and internal-testing markers")
    print("top level: " + ", ".join(sorted(os.listdir(root))))
    found = 0
    for directory, _, filenames in os.walk(root):
        for filename in filenames:
            if not filename.endswith(".plist"):
                continue
            plist_path = os.path.join(directory, filename)
            try:
                with open(plist_path, "rb") as handle:
                    data = plistlib.load(handle)
            except Exception:
                continue
            for key_path, value in leaves(data):
                text = f"{key_path} {value}".lower()
                if "internal" in text or "testflight" in text:
                    print(f"{os.path.relpath(plist_path, root)}: {key_path} = {value!r}")
                    found += 1
    if not found:
        print("No plist entry mentions internal testing or TestFlight.")
    print("::endgroup::")

step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
if step_summary:
    with open(step_summary, "a", encoding="utf-8") as handle:
        handle.write(f"### FreeFlow {mode} check: {'passed' if not failures else 'FAILED'}\n\n")
        handle.write("| Bundle | Bundle ID | Build | App Groups | Keychain groups | application-identifier | get-task-allow |\n")
        handle.write("|---|---|---|---|---|---|---|\n")
        for row in summary:
            handle.write("| " + " | ".join(f"`{cell}`" for cell in row) + " |\n")
        for failure in failures:
            handle.write(f"\n- {failure}")
        handle.write("\n\n")

if failures:
    for failure in failures:
        print(f"::error::{failure}")
    sys.exit(1)
print(f"{mode} check passed for {prefix} (team {team_id}, build {build_number}).")
PY
