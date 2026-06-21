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
# --identifier を明示することで、再ビルド時も TCC から「同じアプリ」と認識されやすくする
codesign --sign - --identifier local.kura.app --force --options runtime "$APP" 2>&1 | grep -v "replacing existing signature" || true

echo "==> built: $ROOT/$APP"
echo ""
echo "起動: open $APP"
echo "停止: pkill Kura"
echo ""
echo "アクセシビリティ権限が効かない場合:"
echo "  1. システム設定 → プライバシー → アクセシビリティ で Kura を「−」で削除"
echo "  2. pkill Kura && open $APP で再起動、プロンプトで許可"
echo "  3. もう一度 pkill Kura && open $APP"
