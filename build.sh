#!/bin/bash
# Build Kura.app — release ビルドして .app バンドルを組み立てる
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="Kura.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/Kura"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "ERROR: binary not found at $BIN_PATH"
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/Kura"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> ad-hoc codesign"
codesign --sign - --force --deep --options runtime "$APP" 2>&1 | grep -v "replacing existing signature" || true

echo "==> built: $ROOT/$APP"
echo ""
echo "起動: open $APP"
echo "停止: pkill Kura"
