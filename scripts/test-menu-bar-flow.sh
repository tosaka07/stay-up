#!/bin/zsh

set -euo pipefail

repo_root=${0:A:h:h}
app_path="$repo_root/build/StayUp.app"
app_executable="$app_path/Contents/MacOS/StayUp"
cli="$app_path/Contents/MacOS/stay-up"

if pgrep -f "$app_executable" >/dev/null; then
    print -u2 "FAIL: StayUp is already running"
    exit 1
fi

cleanup() {
    osascript -e 'tell application "StayUp" to quit' >/dev/null 2>&1 || true
}
trap cleanup EXIT

open -g -a "$app_path" --args --stay-up-background

for _ in {1..50}; do
    app_pid=$(pgrep -nf "$app_executable" || true)
    status_json=$("$cli" status --json)
    if [[ -n "$app_pid" && "$status_json" != *"StayUp に接続できません"* ]]; then
        break
    fi
    sleep 0.1
done

if [[ -z "${app_pid:-}" || "$status_json" == *"StayUp に接続できません"* ]]; then
    print -u2 "FAIL: StayUp did not become ready"
    exit 1
fi

osascript \
    -e 'tell application "System Events" to tell process "StayUp" to click menu bar item 1 of menu bar 2' \
    -e 'delay 0.3' \
    -e 'tell application "System Events" to tell process "StayUp" to tell menu item "StayUpを開始" of menu 1 of menu bar item 1 of menu bar 2 to perform action "AXShowMenu"' \
    -e 'delay 0.2' \
    -e 'tell application "System Events" to tell process "StayUp" to click menu item "30分で開始" of menu 1 of menu item "StayUpを開始" of menu 1 of menu bar item 1 of menu bar 2' \
    -e 'delay 0.8'

active_json=$("$cli" status --json)
if [[ "$active_json" != *'"leaseCount" : 1'* ||
      "$active_json" != *'"kind" : "interactive"'* ||
      "$active_json" != *'"endsReason" : "ttl"'* ]]; then
    print -u2 "FAIL: menu bar did not start one timed interactive session"
    exit 1
fi

osascript \
    -e 'tell application "System Events" to tell process "StayUp" to click menu bar item 1 of menu bar 2' \
    -e 'delay 0.3' \
    -e 'tell application "System Events" to tell process "StayUp" to click menu item "すべて解除" of menu 1 of menu bar item 1 of menu bar 2' \
    -e 'delay 0.8'

idle_json=$("$cli" status --json)
if [[ "$idle_json" != *'"leaseCount" : 0'* ]]; then
    print -u2 "FAIL: menu bar did not release the session"
    exit 1
fi

if ! kill -0 "$app_pid" 2>/dev/null; then
    print -u2 "FAIL: StayUp crashed during the menu bar flow"
    exit 1
fi

print "PASS: menu bar selected 30 minutes, started, and released safely"
