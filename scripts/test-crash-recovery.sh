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
    "$cli" stop --owner crash-recovery-e2e >/dev/null 2>&1 || true
    osascript -e 'tell application "StayUp" to quit' >/dev/null 2>&1 || true
}
trap cleanup EXIT

read_sleep_disabled() {
    /usr/bin/pmset -g |
        awk '$1 == "SleepDisabled" { print $2; exit }'
}

"$cli" acquire \
    --owner crash-recovery-e2e \
    --label "クラッシュ復元E2E" \
    -t 5m \
    --json >/dev/null

status_json=$("$cli" status --json)
if [[ "$status_json" != *'"capability" : "full"'* ]]; then
    print "SKIP: Developer ID署名済みヘルパーが有効ではありません"
    exit 77
fi

if [[ "$(read_sleep_disabled)" != "1" ]]; then
    print -u2 "FAIL: the helper did not set SleepDisabled=1"
    exit 1
fi

app_pid=$(pgrep -nf "$app_executable" || true)
if [[ -z "$app_pid" ]]; then
    print -u2 "FAIL: StayUp process was not found"
    exit 1
fi

kill -9 "$app_pid"

for _ in {1..100}; do
    if [[ "$(read_sleep_disabled)" == "0" ]]; then
        break
    fi
    sleep 0.1
done

if [[ "$(read_sleep_disabled)" != "0" ]]; then
    print -u2 "FAIL: SleepDisabled was not restored after SIGKILL"
    exit 1
fi

open -g -a "$app_path" --args --stay-up-background

for _ in {1..50}; do
    restarted_json=$("$cli" status --json)
    if [[ "$restarted_json" != *"StayUp に接続できません"* ]]; then
        break
    fi
    sleep 0.1
done

if [[ "$restarted_json" != *'"leaseCount" : 0'* ]]; then
    print -u2 "FAIL: a stale lease survived the restart"
    exit 1
fi

print "PASS: SIGKILL restored SleepDisabled and restart remained idle"
