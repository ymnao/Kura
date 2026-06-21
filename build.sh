#!/bin/bash
# Build Kura.app — release ビルドして .app バンドルを組み立てる
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="Kura.app"
BUNDLE_ID="local.kura.app"

# 既存プロセスを停止（codesign 中の差し替えと、新バイナリでの AX 権限プロンプトのため）
if pgrep -x Kura > /dev/null; then
    echo "==> stopping running Kura"
    pkill -x Kura || true
    sleep 0.5
fi

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
# ad-hoc 署名では CDHash が毎ビルド変わるため、--identifier だけでは TCC は「同じアプリ」と
# 認識しきれない。Hardened Runtime (--options runtime) は dyld 層の保護で TCC とは別レイヤー、
# ad-hoc 配布では益が薄く副作用源になり得るので外す。
codesign --sign - --identifier "$BUNDLE_ID" --force "$APP" 2>&1 | grep -v "replacing existing signature" || true

# CDHash 変化による TCC の「別アプリ判定」を避けるため、古い entry を毎ビルドでクリアする。
# 起動時に必ず新規プロンプトが出るが、「許可済みなのに動かない」状態は無くなる。
# (Apple DTS 推奨: ad-hoc では TCC thrash が前提)
echo "==> reset TCC accessibility entry for $BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID" > /dev/null 2>&1 || true

echo "==> built: $ROOT/$APP"
echo ""
echo "起動:  open $APP    (起動時にアクセシビリティ権限プロンプトが出るので許可)"
echo "停止:  pkill Kura"
echo ""
echo "プロンプトで許可した後、もう一度 pkill Kura && open $APP で AX 有効状態になります。"
