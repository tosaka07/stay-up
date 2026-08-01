#!/bin/zsh

set -euo pipefail

# MenuBarExtra のラベル更新が起動処理を再帰的に無効化すると、アプリは
# applicationDidFinishLaunching から抜けず CPU とメモリを消費し続ける。
# 実際の .app を起動し、メインスレッドが起動処理を抜けて収束したことを検査する。
repo_dir="${0:A:h:h}"
app_path="${repo_dir}/build/StayUp.app"
executable_path="${app_path}/Contents/MacOS/StayUp"
pid=""
sample_file=""

cleanup() {
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        kill -TERM "${pid}" 2>/dev/null || true
    fi
    if [[ -n "${sample_file}" && -f "${sample_file}" ]]; then
        rm -f -- "${sample_file}"
    fi
}
trap cleanup EXIT

if [[ ! -x "${executable_path}" ]]; then
    print -u2 "FAIL: executable not found: ${executable_path}"
    exit 1
fi

existing_pid="$(pgrep -f "^${executable_path}$" || true)"
if [[ -n "${existing_pid}" ]]; then
    print -u2 "FAIL: StayUp is already running (PID ${existing_pid})"
    exit 1
fi

open -n "${app_path}"

for _ in {1..50}; do
    pid="$(pgrep -n -f "^${executable_path}$" || true)"
    [[ -n "${pid}" ]] && break
    sleep 0.1
done

if [[ -z "${pid}" ]]; then
    print -u2 "FAIL: StayUp process did not appear"
    exit 1
fi

sleep 4

if ! kill -0 "${pid}" 2>/dev/null; then
    print -u2 "FAIL: StayUp exited during launch"
    exit 1
fi

rss_kb="$(ps -p "${pid}" -o rss= | tr -d ' ')"
cpu_percent="$(ps -p "${pid}" -o %cpu= | tr -d ' ')"
sample_file="$(mktemp /private/tmp/stayup-launch-health.XXXXXX)"
/usr/bin/sample "${pid}" 1 10 -file "${sample_file}" >/dev/null

if grep -q "applicationDidFinishLaunching" "${sample_file}"; then
    print -u2 "FAIL: main thread is still inside applicationDidFinishLaunching after 4 seconds"
    print -u2 "PID=${pid} RSS_KB=${rss_kb} CPU_PERCENT=${cpu_percent}"
    exit 1
fi

if (( rss_kb >= 524288 )); then
    print -u2 "FAIL: launch memory exceeded 512 MiB"
    print -u2 "PID=${pid} RSS_KB=${rss_kb} CPU_PERCENT=${cpu_percent}"
    exit 1
fi

if (( cpu_percent >= 80.0 )); then
    print -u2 "FAIL: CPU did not settle below 80%"
    print -u2 "PID=${pid} RSS_KB=${rss_kb} CPU_PERCENT=${cpu_percent}"
    exit 1
fi

print "PASS: StayUp launch settled"
print "PID=${pid} RSS_KB=${rss_kb} CPU_PERCENT=${cpu_percent}"
