#!/bin/bash
# Builds build/MemBar.app from the SwiftPM executable.
#
# 整个构建有硬上限（BUILD_TIMEOUT，默认 60 秒）。任何一步卡住——swift-frontend 挂死、codesign
# 等网络时间戳、冒烟测试不退出——都会被整棵进程树杀掉并判为构建失败，不让终端无限等下去。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=Scripts/timeout.sh
source "$ROOT/Scripts/timeout.sh"

CONFIG="${CONFIG:-release}"
APP_NAME="MemBar"
APP="$ROOT/build/$APP_NAME.app"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-60}"

if ! [[ "$BUILD_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: BUILD_TIMEOUT 必须是正整数（当前：${BUILD_TIMEOUT}）" >&2
  exit 1
fi

START=$SECONDS
DEADLINE=$(( START + BUILD_TIMEOUT ))

# Runs one build step inside what is left of the total budget. The step header goes to stderr so
# that callers can capture the command's own stdout.
step() {
  local label=$1
  shift
  local left=$(( DEADLINE - SECONDS ))
  if [ "$left" -le 0 ]; then
    echo "error: 构建已用完 ${BUILD_TIMEOUT}s 预算（${label} 未开始），判定失败" >&2
    exit 1
  fi
  echo "==> ${label}（预算剩余 ${left}s）" >&2
  local status=0
  run_with_timeout "$left" "$@" || status=$?
  if [ "$status" -eq 124 ]; then
    echo "error: $label 超过 ${BUILD_TIMEOUT}s 构建预算，判定失败" >&2
    exit 1
  fi
  if [ "$status" -ne 0 ]; then
    echo "error: ${label} 失败（退出码 ${status}）" >&2
    exit "$status"
  fi
}

step "swift build ($CONFIG)" \
  swift build -c "$CONFIG" --product "$APP_NAME" -Xlinker -dead_strip

BIN_DIR="$(step "定位产物" swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [ ! -x "$BIN" ]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP" >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICON="$ROOT/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then
  mkdir -p "$ROOT/Resources"
  step "生成图标" swift "$ROOT/Scripts/GenerateAppIcon.swift" "$ICON"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# Local symbols are not needed at runtime and only grow the binary.
strip -x "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
  step "codesign (adhoc)" codesign --force --sign - "$APP"
else
  step "codesign ($SIGN_IDENTITY)" \
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
step "codesign verify" codesign --verify --strict "$APP"

step "smoke test (--diagnostics)" \
  "$APP/Contents/MacOS/$APP_NAME" --diagnostics | sed 's/^/    /'

echo "ok: ${APP}（$(du -sh "$APP" | cut -f1)，用时 $(( SECONDS - START ))s / 上限 ${BUILD_TIMEOUT}s）"