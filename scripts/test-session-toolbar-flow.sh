#!/bin/zsh

set -euo pipefail

repo_root=${0:A:h:h}
app_path="$repo_root/build/StayUp.app"
executable_path="$app_path/Contents/MacOS/StayUp"
duration_label=${1:-30分}
menu_item_label="${duration_label}で開始"
mode=${2:-stop}
app_pid=""

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

osascript \
    -e 'tell application "StayUp" to activate' \
    -e 'delay 0.2' \
    -e 'tell application "System Events" to tell process "StayUp" to set selected of row 1 of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1 to true' \
    -e 'delay 0.2'

default_help_before=$(osascript -e 'tell application "System Events" to tell process "StayUp" to get help of pop up button 1 of group 1 of toolbar 1 of window 1')

osascript \
    -e 'tell application "System Events" to tell process "StayUp" to click menu button 1 of pop up button 1 of group 1 of toolbar 1 of window 1' \
    -e 'delay 0.2' \
    -e "tell application \"System Events\" to tell process \"StayUp\" to click menu item \"$menu_item_label\" of menu 1 of menu button 1 of pop up button 1 of group 1 of toolbar 1 of window 1" \
    -e 'delay 0.5'

split_button_exists=$(osascript -e 'tell application "System Events" to tell process "StayUp" to exists pop up button 1 of group 1 of toolbar 1 of window 1')
if [[ "$split_button_exists" == "true" ]]; then
    print -u2 "FAIL: choosing $duration_label did not start a session immediately"
    exit 1
fi

if [[ "$mode" == "stop" ]]; then
    osascript \
        -e 'tell application "System Events" to tell process "StayUp" to click button 2 of toolbar 1 of window 1' \
        -e 'delay 1'
    default_help_after=$(osascript -e 'tell application "System Events" to tell process "StayUp" to get help of pop up button 1 of group 1 of toolbar 1 of window 1')
    if [[ "$default_help_after" != "$default_help_before" ]]; then
        print -u2 "FAIL: choosing $duration_label changed the configured default duration"
        exit 1
    fi
else
    sleep 1
fi

if ! kill -0 "$app_pid" 2>/dev/null; then
    print -u2 "FAIL: StayUp crashed after $mode with duration $duration_label"
    exit 1
fi

osascript -e 'tell application "StayUp" to quit'
print "PASS: StayUp remained alive after $mode with duration $duration_label"
