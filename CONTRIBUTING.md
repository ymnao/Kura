# Contributing

## 開発環境

- macOS 14 (Sonoma) 以降
- Xcode 16 以降

## ビルド

```bash
swift build           # debug
./build.sh            # release + .app バンドル
swift run             # 直接実行（.app を介さない）
```

## 停止

```bash
pkill Kura
```

## ブランチ運用

- `main`: 安定版（直接コミット禁止）
- `feature/<name>`: 新機能
- `fix/<name>`: バグ修正
- `refactor/<target>`: リファクタリング
- `docs/<target>`: ドキュメント

ブランチ名は英語小文字とハイフン。

## コミットメッセージ

```
<type>: <subject>

<body>
```

### Type

- `feat`: 新機能
- `fix`: バグ修正
- `refactor`: リファクタリング
- `style`: スタイル変更（機能影響なし）
- `docs`: ドキュメント
- `chore`: ビルド・設定変更
- `ci`: CI 関連

### 例

```
feat: 設定画面に登録アプリ追加ボタンを実装

- NSWorkspace で起動中アプリを一覧
- 選択したアプリを UserDefaults に永続化
```

## PR ガイドライン

- 1 PR = 1 機能 / 1 修正
- description には何を / なぜ / どう確認したか
- レビュー指摘にはすべて返信する（修正 or 理由付きで対応しない）

## 禁止事項

- `main` への直接コミット
- `git push --force` / `--force-with-lease`（明示許可なし）
- `git commit --amend`（push 済みコミット）
- `git reset --hard`
- lint 無効化コメントでの誤魔化し（修正で対応）

## コードスタイル

- インデントはスペース 4
- 行末スペース禁止
- ファイル末尾に改行 1 つ
- `.editorconfig` を参照

## テスト

（追加されたら追記）
