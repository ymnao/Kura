#!/bin/bash
# Build Kura.app — release ビルドして .app バンドルを組み立てる
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="Kura.app"
BUNDLE_ID="io.github.ymnao.kura"
APP_EXEC="$ROOT/$APP/Contents/MacOS/Kura"

# 既存プロセスを停止（codesign 中の差し替えと、新バイナリでの AX 権限プロンプトのため）。
# 別ディレクトリの同名 Kura や、たまたま "Kura" という名のプロセスを巻き込まないため、
# このリポジトリの Kura.app 実行ファイルを絶対パスで指定して `-f` (full command line) と
# `-x` (完全一致) で対象を限定する。
# 注: pgrep/pkill の pattern は -x 指定でも ERE として解釈されるため、APP_EXEC の
# "." や、チェックアウト先に含まれ得る "[]()+?{|^$*\" 等を必ずリテラル化する。
APP_EXEC_REGEX=$(printf '%s' "$APP_EXEC" | sed 's/[][().*+?^$|{}\\]/\\&/g')
if pgrep -fx "$APP_EXEC_REGEX" > /dev/null 2>&1; then
    echo "==> stopping running Kura ($APP_EXEC)"
    pkill -fx "$APP_EXEC_REGEX" || true
    # SIGTERM 受信から実プロセス終了 + binary のファイルロック解放までの猶予
    sleep 0.5
fi

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/Kura"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

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
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc codesign"
# ad-hoc 署名では CDHash が毎ビルド変わるため、--identifier だけでは TCC は「同じアプリ」と
# 認識しきれない。Hardened Runtime (--options runtime) は dyld 層の保護で TCC とは別レイヤー、
# ad-hoc 配布では益が薄く副作用源になり得るので外す。
# 出力をキャプチャしてから「replacing existing signature」だけ抑制する。
# `codesign | grep | true` 形式だと codesign 自体の失敗が握り潰されるので
# 終了コードは個別に評価する。
codesign_log=$(codesign --sign - --identifier "$BUNDLE_ID" --force "$APP" 2>&1) || {
    echo "ERROR: codesign failed:"
    echo "$codesign_log"
    exit 1
}
echo "$codesign_log" | grep -v "replacing existing signature" || true

# CDHash 変化による TCC の「別アプリ判定」を避けるため、古い entry を毎ビルドでクリアする。
# 起動時に必ず新規プロンプトが出るが、「許可済みなのに動かない」状態は無くなる。
# (Apple DTS 推奨: ad-hoc では TCC thrash が前提)
# 失敗しても処理は続けるが、明確に警告を出して「reset 済み」と誤認させない。
echo "==> reset TCC accessibility entry for $BUNDLE_ID"
if ! tccutil_err=$(tccutil reset Accessibility "$BUNDLE_ID" 2>&1); then
    echo "WARNING: tccutil reset 失敗: $tccutil_err"
    echo "         古い TCC entry が残っている可能性があります。アクセシビリティ"
    echo "         権限のプロンプトが出ない/効かない場合は、システム設定 → プライバシー"
    echo "         → アクセシビリティ から Kura を手動で削除してください。"
fi

echo "==> built: $ROOT/$APP"
echo ""
echo "起動:  open $APP    (起動時にアクセシビリティ権限プロンプトが出るので許可)"
echo "停止:  pkill Kura"
echo ""
echo "プロンプトで許可した後、もう一度 pkill Kura && open $APP で AX 有効状態になります。"
