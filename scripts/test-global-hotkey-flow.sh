#!/bin/zsh

set -euo pipefail

repo_root=${0:A:h:h}
app_path="$repo_root/build/StayUp.app"
executable_path="$app_path/Contents/MacOS/StayUp"
hotkey=${1:-1}
app_pid=""

case "$hotkey" in
    1) start_key_code=18 ;;
    2) start_key_code=19 ;;
    3) start_key_code=20 ;;
    4) start_key_code=21 ;;
    *)
        print -u2 "FAIL: hotkey must be 1, 2, 3, or 4"
        exit 1
        ;;
esac

cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

open -n "$app_path"

for _ in {1..50}; do
    app_pid=$(pgrep -nf "$executable_path" || true)
    if [[ -n "$app_pid" ]] && osascript -e 'tell application "System Events" to exists process "StayUp"' | grep -q true; then
        break
    fi
    sleep 0.1
done

if [[ -z "${app_pid:-}" ]]; then
    print -u2 "FAIL: StayUp did not launch"
    exit 1
fi

for _ in {1..50}; do
    start_control_exists=$(osascript -e 'tell application "System Events" to tell process "StayUp" to exists pop up button 1 of group 1 of toolbar 1 of window 1')
    [[ "$start_control_exists" == "true" ]] && break
    sleep 0.1
done

if [[ "${start_control_exists:-false}" != "true" ]]; then
    print -u2 "FAIL: StayUp toolbar did not become ready"
    exit 1
fi

sleep 0.5

osascript \
    -e 'tell application "Finder" to activate' \
    -e 'delay 0.2' \
    -e "tell application \"System Events\" to key code $start_key_code using {control down, option down, command down}" \
    -e 'delay 0.5'

start_control_exists=$(osascript -e 'tell application "System Events" to tell process "StayUp" to exists pop up button 1 of group 1 of toolbar 1 of window 1')
if [[ "$start_control_exists" == "true" ]]; then
    print -u2 "FAIL: global hotkey $hotkey did not start StayUp while Finder was active"
    exit 1
fi

osascript \
    -e 'tell application "Finder" to activate' \
    -e 'tell application "System Events" to key code 29 using {control down, option down, command down}' \
    -e 'delay 0.5'

start_control_exists=$(osascript -e 'tell application "System Events" to tell process "StayUp" to exists pop up button 1 of group 1 of toolbar 1 of window 1')
if [[ "$start_control_exists" != "true" ]]; then
    print -u2 "FAIL: global stop hotkey did not release all sessions"
    exit 1
fi

osascript -e 'tell application "StayUp" to quit'
print "PASS: global start $hotkey and stop 0 worked while Finder was active"
