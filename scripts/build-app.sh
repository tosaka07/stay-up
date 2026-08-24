#!/usr/bin/env bash
# StayUp.app を組み立てる。
#
# SwiftPM は .app バンドルを作れないので、ビルド成果物をここで配置する。
#
# Usage:
#   scripts/build-app.sh [--release] [--universal] [--sign <identity|auto>] [--install]

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="debug"
SIGN_IDENTITY=""
INSTALL=0
UNIVERSAL=0

while (( $# > 0 )); do
  case "$1" in
    --release)   CONFIGURATION="release"; shift ;;
    --universal) UNIVERSAL=1; shift ;;
    --sign)    SIGN_IDENTITY="${2:?--sign には識別子が必要です}"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "不明な引数です: $1" >&2; exit 2 ;;
  esac
done

if [[ "$SIGN_IDENTITY" == "auto" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning |
      sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' |
      head -n 1
  )"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Developer ID Application 証明書が見つかりません。" >&2
    exit 3
  fi
fi

APP_NAME="StayUp"
BUNDLE="build/${APP_NAME}.app"
# 空配列の展開は bash 3.2 の set -u で落ちるので、存在するときだけ展開する
ARCH_FLAGS=()
BUILD_LABEL="$CONFIGURATION"
if (( UNIVERSAL )); then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  BUILD_LABEL="${CONFIGURATION}, universal"
fi
BIN_DIR="$(swift build --configuration "$CONFIGURATION" \
  ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> ビルド (${BUILD_LABEL})"
swift build --configuration "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

echo "==> バンドルを構成"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
mkdir -p "$BUNDLE/Contents/Library/LaunchDaemons"

# 実行ファイル名は Info.plist の CFBundleExecutable に合わせる
cp "$BIN_DIR/StayUpApp"    "$BUNDLE/Contents/MacOS/${APP_NAME}"
cp "$BIN_DIR/stay-up"      "$BUNDLE/Contents/MacOS/stay-up"
cp "$BIN_DIR/StayUpHelper" "$BUNDLE/Contents/MacOS/StayUpHelper"

cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/dev.tosaka.StayUp.Helper.plist \
   "$BUNDLE/Contents/Library/LaunchDaemons/dev.tosaka.StayUp.Helper.plist"

printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

if (( UNIVERSAL )); then
  echo "==> アーキテクチャを検証"
  for exe in "${APP_NAME}" stay-up StayUpHelper; do
    ARCHS="$(lipo -archs "$BUNDLE/Contents/MacOS/$exe")"
    if [[ "$ARCHS" != *arm64* || "$ARCHS" != *x86_64* ]]; then
      echo "$exe がユニバーサルではありません: $ARCHS" >&2
      exit 5
    fi
    echo "    $exe: $ARCHS"
  done
fi

echo "==> アイコンをコンパイル"
if ACTOOL="$(xcrun --find actool 2>/dev/null)"; then
  # Assets.car（Liquid Glass 対応の合成アイコン）と StayUp.icns（従来の窓口）が出る。
  # actool は .icon を相対パスで受け取れないので絶対パスを渡す。
  if ! ICON_LOG="$(
    "$ACTOOL" "$PWD/Resources/${APP_NAME}.icon" \
      --compile "$PWD/$BUNDLE/Contents/Resources" \
      --platform macosx \
      --minimum-deployment-target 26.0 \
      --app-icon "$APP_NAME" \
      --output-partial-info-plist "$PWD/build/icon-partial.plist" 2>&1
  )"; then
    echo "$ICON_LOG" >&2
    echo "アイコンのコンパイルに失敗しました。" >&2
    exit 4
  fi
else
  echo "    警告: actool が見つかりません（Xcode 26 が必要）。" >&2
  echo "          アイコンなしで続行します。" >&2
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> 署名 (${SIGN_IDENTITY})"
  # ヘルパーを先に署名してからアプリを署名する（内側から外側へ）
  codesign --force --options runtime --timestamp \
    --identifier dev.tosaka.StayUp.Helper \
    --sign "$SIGN_IDENTITY" "$BUNDLE/Contents/MacOS/StayUpHelper"
  codesign --force --options runtime --timestamp \
    --identifier dev.tosaka.StayUp.CLI \
    --sign "$SIGN_IDENTITY" "$BUNDLE/Contents/MacOS/stay-up"
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$BUNDLE"

  echo "==> 署名を検証"
  codesign --verify --strict --verbose=2 "$BUNDLE/Contents/MacOS/StayUpHelper"
  codesign --verify --strict --verbose=2 "$BUNDLE/Contents/MacOS/stay-up"
  codesign --verify --deep --strict --verbose=2 "$BUNDLE"

  APP_TEAM_ID="$(
    codesign -dv --verbose=4 "$BUNDLE" 2>&1 |
      sed -n 's/^TeamIdentifier=//p'
  )"
  HELPER_TEAM_ID="$(
    codesign -dv --verbose=4 "$BUNDLE/Contents/MacOS/StayUpHelper" 2>&1 |
      sed -n 's/^TeamIdentifier=//p'
  )"
  CLI_TEAM_ID="$(
    codesign -dv --verbose=4 "$BUNDLE/Contents/MacOS/stay-up" 2>&1 |
      sed -n 's/^TeamIdentifier=//p'
  )"
  if [[ -z "$APP_TEAM_ID" ||
        "$APP_TEAM_ID" != "$HELPER_TEAM_ID" ||
        "$APP_TEAM_ID" != "$CLI_TEAM_ID" ]]; then
    echo "アプリ、CLI、ヘルパーの Team ID が一致しません。" >&2
    exit 3
  fi
  echo "    Team ID: $APP_TEAM_ID"
else
  echo "==> 署名なし（ad-hoc）"
  # 未署名だと SMAppService がヘルパーを登録できない。
  # アプリ自体は degraded（アイドル抑止のみ）で動く。
  codesign --force --identifier dev.tosaka.StayUp.Helper \
    --sign - "$BUNDLE/Contents/MacOS/StayUpHelper" 2>/dev/null || true
  codesign --force --sign - "$BUNDLE" 2>/dev/null || true
  echo "    注意: ヘルパーの登録には Developer ID 署名が必要です。"
  echo "          未署名のままでも、アイドルスリープ抑止だけは動作します。"
fi

echo "==> 完成: $BUNDLE"

if (( INSTALL )); then
  DEST="$HOME/Applications/${APP_NAME}.app"
  echo "==> インストール: $DEST"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$BUNDLE" "$DEST"

  LINK_DIR="$HOME/.local/bin"
  mkdir -p "$LINK_DIR"
  ln -sf "$DEST/Contents/MacOS/stay-up" "$LINK_DIR/stay-up"
  echo "    CLI: $LINK_DIR/stay-up"
fi
