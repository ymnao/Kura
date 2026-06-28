#!/bin/bash
# Release Kura.dmg — release ビルド + 作り込み dmg (背景画像 + アイコン配置固定) を組み立てる
# 必要: macOS 14+, Xcode, Resources/dmg-background.png
#
# レイアウト同期メモ: 下記のアイコン位置 {140, 200} / {400, 200} は
# Resources/dmg-background.svg (viewBox 540x380, 矢印 translate(270, 200)) を前提に
# 決めている。SVG を編集した場合は WIN_WIDTH/HEIGHT および本スクリプトの position も同期更新すること。
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
# trap で STAGING の削除と /Volumes/Kura の detach 両方をカバー
# (osascript / hdiutil convert 失敗時に mount 残留して次回 release が衝突するのを防ぐ)
STAGING=$(mktemp -d)
MOUNT_POINT="/Volumes/$VOLNAME"
cleanup() {
    rm -rf "$STAGING"
    if [[ -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" > /dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

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
# -nobrowse だと Finder が disk を認識しないため AppleScript の `tell disk "Kura"` が -1728 で失敗する。
# 代わりに /Volumes/Kura に固定マウント + -noautoopen で Finder window auto-open だけ抑制する。
# (MOUNT_POINT は Section 2 の cleanup() で定義済み)
if [[ -d "$MOUNT_POINT" ]]; then
    echo "==> detaching existing $MOUNT_POINT"
    hdiutil detach "$MOUNT_POINT" > /dev/null 2>&1 || true
fi
hdiutil attach "$TMP_DMG" -noautoopen -readwrite -mountpoint "$MOUNT_POINT" > /dev/null
sleep 2  # Finder が disk を認識するまで待つ

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
        -- close + open 二重で .DS_Store にレイアウトを確実に焼き込む (片方だけだと反映漏れあり、典型的な dmg 作成パターン)
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

# 6. dmg を unmount
hdiutil detach "$MOUNT_POINT" > /dev/null

# 7. UDZO (圧縮 read-only) に変換して最終 dmg を生成
echo "==> compress to UDZO"
rm -f "$DMG"
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG" > /dev/null
rm -f "$TMP_DMG"

echo "==> built: $ROOT/$DMG"
echo ""
echo "テスト: open $DMG    (Finder ウィンドウが背景画像 + Drag & Drop UI で開くはず)"
