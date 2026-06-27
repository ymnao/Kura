#!/bin/bash
# Release Kura.dmg — release ビルド + 作り込み dmg (背景画像 + アイコン配置固定) を組み立てる
# 必要: macOS 14+, Xcode, Resources/dmg-background.png
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP="Kura.app"
DMG="Kura.dmg"
VOLNAME="Kura"
BACKGROUND="$ROOT/Resources/dmg-background.png"
WIN_WIDTH=540
WIN_HEIGHT=380
ICON_SIZE=96

# 1. Kura.app をビルド (build.sh 内で ad-hoc 署名まで済む)
echo "==> ./build.sh release"
./build.sh release

if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP not found after build" >&2
    exit 1
fi
if [[ ! -f "$BACKGROUND" ]]; then
    echo "ERROR: background image not found at $BACKGROUND" >&2
    exit 1
fi

# 2. staging ディレクトリ作成
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "==> assembling staging at $STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$STAGING/.background"
cp "$BACKGROUND" "$STAGING/.background/dmg-background.png"

# 3. UDRW (read-write) dmg を一旦作成 — レイアウトを書き込む必要があるため
TMP_DMG="$ROOT/.tmp-kura.dmg"
rm -f "$TMP_DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDRW "$TMP_DMG" > /dev/null

# 4. マウントして Finder ウィンドウのレイアウトを焼き込む
MOUNT_DIR=$(mktemp -d)
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -readwrite > /dev/null

# 5. osascript で Finder ウィンドウ設定 (ウィンドウサイズ / アイコン位置 / 背景画像)
echo "==> applying Finder window layout"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, $((400 + WIN_WIDTH)), $((100 + WIN_HEIGHT))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set background picture of viewOptions to file ".background:dmg-background.png"
        set position of item "$APP" of container window to {140, 200}
        set position of item "Applications" of container window to {400, 200}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

# 6. dmg を unmount
hdiutil detach "$MOUNT_DIR" > /dev/null
rm -rf "$MOUNT_DIR"

# 7. UDZO (圧縮 read-only) に変換して最終 dmg を生成
echo "==> compress to UDZO"
rm -f "$DMG"
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG" > /dev/null
rm -f "$TMP_DMG"

echo "==> built: $ROOT/$DMG"
echo ""
echo "テスト: open $DMG    (Finder ウィンドウが背景画像 + Drag & Drop UI で開くはず)"
