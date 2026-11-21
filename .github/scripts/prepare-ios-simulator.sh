#!/usr/bin/env bash
# Sets up a booted iOS simulator for FreeFlow's keyboard UI tests without
# touching the Settings app, and reports the resulting state.
#
#   prepare-ios-simulator.sh configure <udid> <path to FreeFlow.app>
#     1. Installs the app, and with it the keyboard extension.
#     2. Grants the app the microphone (simctl privacy).
#     3. Enables the FreeFlow keyboard after English (AppleKeyboards).
#     4. Keeps the software keyboard up with a hardware keyboard attached,
#        and skips the first-run Slide to Type introduction.
#     5. Shuts the simulator down and turns on the keyboard's Full Access.
#        iOS keeps that as the TCC service kTCCServiceKeyboardNetwork, which
#        simctl privacy can't grant, so the row goes into the simulator's
#        TCC.db directly, while tccd isn't running. The client is the
#        containing app; the keyboard's own ID gets a row too.
#     6. Boots the simulator again, so tccd and the keyboard daemon read it
#        all fresh.
#
#   prepare-ios-simulator.sh report <udid> [<app id> <keyboard id>]
#     Prints the keyboard preferences, the TCC rows for FreeFlow, the
#     KeyboardStatus the keyboard last recorded in the App Group (it says
#     whether the keyboard saw Full Access), and the simulator's recent log
#     lines about Full Access.
#
# This only runs against CI's throwaway simulators. The UI tests check the
# result in the Settings app and fall back to enabling things there.
set -euo pipefail

usage() {
    sed -n '2,20p' "$0" >&2
    exit 64
}

sim_defaults() {
    xcrun simctl spawn "$udid" defaults "$@"
}

tcc_db_path() {
    echo "$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/TCC/TCC.db"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

# Writes allow rows for kTCCServiceKeyboardNetwork with the simulator shut
# down. The values match a recipe that CI runs elsewhere have shown the
# keyboard reading as Full Access: no code requirement (csreq stays NULL), so
# tccd doesn't hold the row to another bundle's signature. Columns the
# runtime's schema lacks are skipped and the rest take their defaults.
grant_keyboard_network() {
    local db=$1
    shift
    python3 -I - "$db" "$@" <<'PY'
import sqlite3
import sys
import time

db, *clients = sys.argv[1:]
service = "kTCCServiceKeyboardNetwork"
connection = sqlite3.connect(db, timeout=30)
columns = {row[1] for row in connection.execute("PRAGMA table_info(access)")}
if not columns:
    sys.exit(f"{db} has no access table")
for client in clients:
    row = {"service": service, "client": client, "client_type": 0, "auth_value": 2,
           "auth_reason": 2, "auth_version": 1, "flags": 0, "last_modified": int(time.time()),
           "allowed": 1, "prompt_count": 1}
    names = [name for name in row if name in columns]
    connection.execute(
        f"INSERT OR REPLACE INTO access ({', '.join(names)}) VALUES ({', '.join('?' for _ in names)})",
        [row[name] for name in names],
    )
connection.commit()
print(f"Granted {service} to {', '.join(clients)}")
PY
}

print_tcc_rows() {
    local db=$1
    shift
    if [ ! -f "$db" ]; then
        echo "No TCC database at $db"
        return 0
    fi
    python3 -I - "$db" "$@" <<'PY'
import sqlite3
import sys

db, *clients = sys.argv[1:]
connection = sqlite3.connect(db, timeout=30)
columns = [row[1] for row in connection.execute("PRAGMA table_info(access)")]
print("access columns:", ", ".join(columns))
wanted = [name for name in ("service", "client", "client_type", "auth_value", "auth_reason", "auth_version")
          if name in columns]
marks = ", ".join("?" for _ in clients)
query = f"SELECT {', '.join(wanted)} FROM access WHERE client IN ({marks}) ORDER BY client, service"
for row in connection.execute(query, clients):
    print("  " + "  ".join(f"{name}={value}" for name, value in zip(wanted, row)))
PY
}

configure() {
    local app=$1
    local appex="$app/PlugIns/FreeFlowKeyboard.appex"
    if [ ! -d "$appex" ]; then
        echo "::error::$appex does not exist; build the app first"
        exit 1
    fi
    local app_id keyboard_id
    app_id=$(plist_value "$app/Info.plist" CFBundleIdentifier)
    keyboard_id=$(plist_value "$appex/Info.plist" CFBundleIdentifier)
    echo "App $app_id, keyboard $keyboard_id, simulator $udid"

    echo "::group::Install the app"
    xcrun simctl install "$udid" "$app"
    # iOS drops AppleKeyboards entries it can't resolve, so wait until the
    # extension is registered before naming it there.
    local attempt registered=""
    for attempt in $(seq 1 30); do
        registered=$(xcrun simctl spawn "$udid" pluginkit -m -v -p com.apple.keyboard-service 2>/dev/null \
            | grep -F "$keyboard_id" || true)
        [ -n "$registered" ] && break
        sleep 1
    done
    if [ -n "$registered" ]; then
        echo "Registered keyboard extension: $registered"
    else
        echo "::warning::pluginkit does not list $keyboard_id after 30 seconds"
    fi
    echo "::endgroup::"

    echo "::group::Grant the microphone"
    xcrun simctl privacy "$udid" grant microphone "$app_id"
    echo "::endgroup::"

    echo "::group::Enable the FreeFlow keyboard"
    echo "AppleKeyboards before:"
    sim_defaults read -g AppleKeyboards || echo "(not set)"
    # English first, so the test switches to FreeFlow with the globe key the
    # way a person does. No emoji keyboard, so one tap reaches FreeFlow.
    # Expanded goes first: without it iOS rebuilds the list from the
    # language settings.
    local english="en_US@sw=QWERTY;hw=Automatic"
    sim_defaults write -g AppleKeyboardsExpanded -int 1
    sim_defaults write -g AppleKeyboards -array "$english" "$keyboard_id"
    # English is the current keyboard and FreeFlow the next, so the globe's
    # target is explicit. The keyboard daemon keeps these here (iOS 26).
    sim_defaults write com.apple.keyboard.preferences KeyboardLastUsed "$english"
    sim_defaults write com.apple.keyboard.preferences KeyboardsCurrentAndNext -array "$english" "$english" "$keyboard_id"
    echo "AppleKeyboards after:"
    sim_defaults read -g AppleKeyboards
    echo "::endgroup::"

    echo "::group::Keep the software keyboard and skip keyboard introductions"
    # iOS minimizes the software keyboard once it has seen a hardware one.
    sim_defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool NO
    sim_defaults write com.apple.Preferences HardwareKeyboardLastSeen -bool NO
    # Different iOS versions read the introduction flags from different
    # domains, so set them in each.
    local domain flag
    for domain in com.apple.keyboard.preferences com.apple.Preferences -g; do
        for flag in DidShowContinuousPathIntroduction DidShowGestureKeyboardIntroduction \
            KeyboardDidShowProductivityTutorial UIKeyboardDidShowInternationalInfoIntroduction; do
            sim_defaults write "$domain" "$flag" -bool YES
        done
    done
    sim_defaults write com.apple.keyboard.preferences KeyboardContinuousPathEnabled -bool NO
    echo "::endgroup::"

    echo "::group::Allow Full Access with the simulator shut down"
    xcrun simctl shutdown "$udid"
    local db
    db=$(tcc_db_path)
    # Full Access belongs to the containing app; the keyboard gets a row too.
    grant_keyboard_network "$db" "$app_id" "$keyboard_id"
    print_tcc_rows "$db" "$app_id" "$keyboard_id"
    echo "::endgroup::"

    echo "::group::Boot the simulator again"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b
    # A fixed status bar keeps the screenshots free of the runner's clock.
    xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
        || echo "Could not override the status bar"
    echo "::endgroup::"

    # What the tests will start from, before any Settings fallback changes it.
    echo "::group::State after the reboot"
    local keyboards
    keyboards=$(sim_defaults read -g AppleKeyboards 2>&1 || true)
    echo "AppleKeyboards: $keyboards"
    if ! grep -qF "$keyboard_id" <<<"$keyboards"; then
        echo "::warning::$keyboard_id is missing from AppleKeyboards after the reboot"
    fi
    local rows
    rows=$(print_tcc_rows "$db" "$app_id" "$keyboard_id")
    echo "$rows"
    if ! grep -q "service=kTCCServiceKeyboardNetwork  client=$app_id " <<<"$rows"; then
        echo "::warning::The Full Access TCC row for $app_id is missing after the reboot"
    fi
    echo "::endgroup::"

    {
        echo "FREEFLOW_APP_ID=$app_id"
        echo "FREEFLOW_KEYBOARD_ID=$keyboard_id"
    } >> "${GITHUB_ENV:-/dev/null}"
}

report() {
    local app_id=${1:-com.zachlatta.freeflow.ios}
    local keyboard_id=${2:-$app_id.keyboard}

    echo "::group::Keyboard preferences"
    echo "AppleKeyboards:"
    sim_defaults read -g AppleKeyboards || echo "(not set)"
    echo "com.apple.keyboard.preferences:"
    sim_defaults read com.apple.keyboard.preferences || echo "(not set)"
    echo "::endgroup::"

    echo "::group::TCC rows for FreeFlow"
    print_tcc_rows "$(tcc_db_path)" "$app_id" "$keyboard_id"
    echo "::endgroup::"

    echo "::group::KeyboardStatus the keyboard recorded in the App Group"
    local group_dir
    group_dir=$(xcrun simctl get_app_container "$udid" "$app_id" "group.$app_id" 2>/dev/null || true)
    if [ -n "$group_dir" ]; then
        python3 -I - "$group_dir/Library/Preferences/group.$app_id.plist" <<'PY' || true
import json
import os
import plistlib
import sys

path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(f"No App Group preferences yet at {path}")
with open(path, "rb") as file:
    preferences = plistlib.load(file)
status = preferences.get("ios_keyboard_status")
if status is None:
    sys.exit("The keyboard has not recorded a KeyboardStatus (it does so only with Full Access)")
if isinstance(status, (bytes, bytearray)):
    status = json.loads(status.decode("utf-8"))
# KeyboardStatus holds flags and failure kinds only, never user content.
print(json.dumps(status, indent=2, sort_keys=True, default=str))
PY
    else
        echo "No App Group container for $app_id"
    fi
    echo "::endgroup::"

    # System log lines about Full Access, if the frameworks log any. They
    # come from the simulator's own processes and the tests use synthetic
    # content only.
    # pkd asks tccd for the containing app's Full Access before it launches
    # the keyboard, and picks the keyboard's sandbox from the answer.
    echo "::group::Full Access answers tccd gave (kTCCServiceKeyboardNetwork)"
    xcrun simctl spawn "$udid" log show --last 30m --info --style compact --predicate \
        '(process == "tccd" OR process == "pkd") AND eventMessage CONTAINS "KeyboardNetwork"' \
        | tail -n 120 || echo "Could not read the simulator log"
    echo "::endgroup::"

    # The keyboard logs only state names, capture events, counts and
    # rates, never text or audio: its status changes show the order of the
    # states each dictation went through, and the capture lines say whether
    # the audio came from WebKit's microphone or the synthetic tone.
    echo "::group::The FreeFlow keyboard's own log (states and capture events)"
    xcrun simctl spawn "$udid" log show --last 45m --info --style compact --predicate \
        "subsystem == \"$keyboard_id\"" \
        | tail -n 400 || echo "Could not read the simulator log"
    echo "::endgroup::"
}

[ $# -ge 2 ] || usage
command=$1
udid=$2
shift 2
case "$command" in
    configure)
        [ $# -eq 1 ] || usage
        configure "$1"
        ;;
    report)
        report "$@"
        ;;
    *)
        usage
        ;;
esac
