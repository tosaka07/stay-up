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

"$cli" acquire --owner ttl-e2e --label "短時間TTL" -t 2s --json >/dev/null

for _ in {1..50}; do
    app_pid=$(pgrep -nf "$app_executable" || true)
    if [[ -n "$app_pid" ]]; then
        break
    fi
    sleep 0.1
done

if [[ -z "${app_pid:-}" ]]; then
    print -u2 "FAIL: StayUp did not launch"
    exit 1
fi

status_json=$("$cli" status --json)
if [[ "$status_json" == *"StayUp に接続できません"* ]]; then
    print -u2 "FAIL: CLI could not connect to the running StayUp app"
    exit 1
fi

active_json=$("$cli" status --json)
if [[ "$active_json" != *'"leaseCount" : 1'* ]]; then
    print -u2 "FAIL: the 2-second lease did not become active"
    exit 1
fi

sleep 3

expired_json=$("$cli" status --json)
if [[ "$expired_json" != *'"leaseCount" : 0'* ]]; then
    print -u2 "FAIL: the 2-second lease did not expire"
    exit 1
fi

if ! kill -0 "$app_pid" 2>/dev/null; then
    print -u2 "FAIL: StayUp crashed when the lease expired"
    exit 1
fi

print "PASS: CLI connected and the 2-second lease expired safely"
