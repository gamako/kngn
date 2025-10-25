実装プランは doc/PLAN.md に記述

# version management
バージョン管理はjjを使用します。gitとは異なる管理概念です。その他の作業はユーザーに相談すること。
```
jj new -m "v0.2.0リリース準備" # 新しい作業ブランチを作成
jj commit -m "変更内容"        # 変更をコミット
jj log                         # 履歴を表示
```
## コミット規約

### Conventional Commits

コミットメッセージは以下の形式に従います：

```
<type>: <subject>

[optional body]
```

#### Type 一覧

| Type | 説明 | 例 |
|------|------|-----|
| `feat` | 新機能 | `feat: CSVインポート機能を追加` |
| `fix` | バグ修正 | `fix: 金額の負値処理を修正` |
| `test` | テスト追加・修正 | `test: Transaction型のテストを追加` |
| `docs` | ドキュメント | `docs: READMEにインストール手順を追加` |
| `refactor` | リファクタリング | `refactor: CSV解析ロジックを分離` |
| `style` | フォーマット | `style: rustfmt適用` |
| `chore` | ビルド・設定 | `chore: 依存関係を更新` |

