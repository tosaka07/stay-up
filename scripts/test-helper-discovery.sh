#!/bin/zsh

set -euo pipefail

repo_root=${0:A:h:h}
app_path=${STAYUP_APP_PATH:-"$repo_root/build/StayUp.app"}
app_executable="$app_path/Contents/MacOS/StayUp"

if [[ ! -x "$app_executable" ]]; then
    print -u2 "FAIL: StayUp executable was not found: $app_executable"
    exit 1
fi

if pgrep -f '/StayUp.app/Contents/MacOS/StayUp$' >/dev/null; then
    print -u2 "FAIL: StayUp is already running"
    exit 1
fi

cleanup() {
    osascript -e 'tell application "StayUp" to quit' >/dev/null 2>&1 || true
}
trap cleanup EXIT

open "$app_path"

for _ in {1..50}; do
    if pgrep -f "$app_executable" >/dev/null; then
        break
    fi
    sleep 0.1
done

if ! pgrep -f "$app_executable" >/dev/null; then
    print -u2 "FAIL: StayUp did not launch"
    exit 1
fi

for _ in {1..50}; do
    if [[ "$(osascript \
        -e 'tell application "System Events" to tell process "StayUp" to exists window 1')" == "true" ]]
    then
        break
    fi
    sleep 0.1
done

if [[ "$(osascript \
    -e 'tell application "System Events" to tell process "StayUp" to exists window 1')" != "true" ]]
then
    print -u2 "FAIL: StayUp did not present its window"
    exit 1
fi

ui_dump=$(osascript \
    -e 'tell application "System Events" to tell process "StayUp" to get entire contents of window 1')

if [[ "$ui_dump" == *'ヘルパーが見つかりません'* ]]; then
    print -u2 "FAIL: SMAppService cannot find the embedded helper"
    exit 1
fi

print "PASS: helper setup is actionable"
