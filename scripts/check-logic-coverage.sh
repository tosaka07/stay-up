#!/bin/zsh

set -euo pipefail

repo_root=${0:A:h:h}
cd "$repo_root"

swift test --enable-code-coverage --quiet

test_binary=".build/debug/StayUpPackageTests.xctest/Contents/MacOS/StayUpPackageTests"
profile=".build/debug/codecov/default.profdata"
report=$(mktemp)
trap 'rm -f "$report"' EXIT

xcrun llvm-cov export "$test_binary" \
    -instr-profile="$profile" \
    -summary-only >"$report"

targets=(
    "Sources/StayUpCore/ControlProtocol.swift"
    "Sources/StayUpCore/DurationParsing.swift"
    "Sources/StayUpCore/HistoryStore.swift"
    "Sources/StayUpCore/Lease.swift"
    "Sources/StayUpCore/LeaseRegistry.swift"
    "Sources/StayUpCore/Settings.swift"
    "Sources/StayUpCore/StateStore.swift"
    "Sources/StayUpService/SessionManager.swift"
)

failed=0
printf '%-48s %8s %10s %8s\n' "対象" "行" "関数" "領域"

for target in "${targets[@]}"; do
    metrics=$(
        jq -r --arg suffix "/$target" '
            .data[0].files[]
            | select(.filename | endswith($suffix))
            | [
                .summary.lines.percent,
                .summary.functions.percent,
                .summary.regions.percent
              ]
            | @tsv
        ' "$report"
    )

    if [[ -z "$metrics" ]]; then
        print -u2 "FAIL: カバレッジ結果に $target がありません"
        failed=1
        continue
    fi

    IFS=$'\t' read -r lines function_coverage regions <<<"$metrics"
    printf '%-48s %7.2f%% %9.2f%% %7.2f%%\n' \
        "$target" "$lines" "$function_coverage" "$regions"

    if (( lines < 100 || function_coverage < 100 || regions < 100 )); then
        failed=1
    fi
done

if (( failed )); then
    print -u2 "FAIL: 根幹ロジックの行・関数・領域カバレッジが100%ではありません"
    exit 1
fi

print "PASS: 根幹ロジックの行・関数・領域カバレッジはすべて100%です"
