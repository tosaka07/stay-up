#!/usr/bin/env bash
# StayUp の配布物を作る。署名 → 公証 → staple → 検証 → ZIP → SHA-256。
#
# Usage:
#   scripts/release.sh [--profile <keychain-profile>] [--sign <identity|auto>]
#                      [--out <dir>] [--skip-build]

set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="StayUp"
SIGN_IDENTITY="auto"
OUT_DIR="dist"
SKIP_BUILD=0

while (( $# > 0 )); do
  case "$1" in
    --profile)    PROFILE="${2:?--profile にはプロファイル名が必要です}"; shift 2 ;;
    --sign)       SIGN_IDENTITY="${2:?--sign には識別子が必要です}"; shift 2 ;;
    --out)        OUT_DIR="${2:?--out にはディレクトリが必要です}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "不明な引数です: $1" >&2; exit 2 ;;
  esac
done

APP_NAME="StayUp"
BUNDLE="build/${APP_NAME}.app"

# --- 1. 署名付きユニバーサルビルド ---------------------------------------
if (( SKIP_BUILD )); then
  echo "==> ビルドを省略（既存の $BUNDLE を使う）"
  [[ -d "$BUNDLE" ]] || { echo "$BUNDLE がありません。" >&2; exit 2; }
else
  ./scripts/build-app.sh --release --universal --sign "$SIGN_IDENTITY"
fi

VERSION="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$BUNDLE/Contents/Info.plist"
)"
echo "==> バージョン: $VERSION"

# 公証は署名済みでないと通らない。ad-hoc ビルドをここまで運ばない。
TEAM_ID="$(codesign -dv --verbose=4 "$BUNDLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ -z "$TEAM_ID" || "$TEAM_ID" == "not set" ]]; then
  echo "Team ID がありません。Developer ID 署名付きでビルドしてください。" >&2
  exit 3
fi

# --- 2. 公証 -------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SUBMIT_ZIP="$WORK/${APP_NAME}-submit.zip"

echo "==> 公証用 ZIP を作成"
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "$SUBMIT_ZIP"

echo "==> Apple へ提出（完了まで待機）"
SUBMIT_JSON="$(
  xcrun notarytool submit "$SUBMIT_ZIP" \
    --keychain-profile "$PROFILE" --wait --output-format json
)" || true

read -r SUBMISSION_ID STATUS <<<"$(
  printf '%s' "$SUBMIT_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(" ")
    sys.exit(0)
print(d.get("id", ""), d.get("status", ""))
'
)"

echo "    id     : ${SUBMISSION_ID:-不明}"
echo "    status : ${STATUS:-不明}"

if [[ -z "$SUBMISSION_ID" ]]; then
  echo "公証の提出に失敗しました。" >&2
  printf '%s\n' "$SUBMIT_JSON" >&2
  exit 6
fi

# Accepted でもログに警告が出ることがあるので、必ず読む。
echo "==> 公証ログを確認"
LOG_JSON="$(xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" 2>&1)" || true
printf '%s' "$LOG_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("    ログを取得できませんでした")
    sys.exit(0)
issues = d.get("issues")
if issues:
    print("    警告 %d 件:" % len(issues))
    for i in issues:
        print("      - [%s] %s: %s" % (
            i.get("severity"), i.get("path"), i.get("message")))
else:
    print("    警告なし")
'

if [[ "$STATUS" != "Accepted" ]]; then
  echo "公証が Accepted になりませんでした（$STATUS）。" >&2
  exit 6
fi

# --- 3. staple と検証 ----------------------------------------------------
echo "==> ticket を添付"
xcrun stapler staple "$BUNDLE"

echo "==> stapler validate"
xcrun stapler validate "$BUNDLE"

echo "==> Gatekeeper 評価"
ASSESS="$(spctl --assess --type execute --verbose=4 "$BUNDLE" 2>&1)"
printf '%s\n' "$ASSESS" | sed 's/^/    /'
if ! printf '%s' "$ASSESS" | grep -q "source=Notarized Developer ID"; then
  echo "Gatekeeper が公証済みと認識しませんでした。" >&2
  exit 7
fi

# --- 4. 最終成果物 -------------------------------------------------------
# ZIP には staple できないので、ticket を付けた .app から作り直す。
ARCH_LIST="$(lipo -archs "$BUNDLE/Contents/MacOS/${APP_NAME}")"
if [[ "$ARCH_LIST" == *arm64* && "$ARCH_LIST" == *x86_64* ]]; then
  ARCH_TAG="universal"
else
  ARCH_TAG="$(printf '%s' "$ARCH_LIST" | tr ' ' '-')"
fi
ARTIFACT="${OUT_DIR}/${APP_NAME}-${VERSION}-${ARCH_TAG}.zip"

echo "==> 最終 ZIP を作成"
mkdir -p "$OUT_DIR"
rm -f "$ARTIFACT" "${ARTIFACT}.sha256"
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ARTIFACT"

( cd "$OUT_DIR" && shasum -a 256 "$(basename "$ARTIFACT")" > "$(basename "$ARTIFACT").sha256" )

echo
echo "==> 完成"
echo "    成果物   : $ARTIFACT"
echo "    サイズ   : $(du -h "$ARTIFACT" | cut -f1)"
echo "    SHA-256  : $(cut -d' ' -f1 "${ARTIFACT}.sha256")"
echo "    Team ID  : $TEAM_ID"
echo "    arch     : $(lipo -archs "$BUNDLE/Contents/MacOS/${APP_NAME}")"
