# JPAgentManager

複数の Mac・複数のリポジトリで動いている Claude Code（主に VSCode 拡張）を、メニューバーから一覧するアプリ。クリックするとそのセッションが前面に出る。

- 状態: P1（1台の Mac で一覧・状態・前面化・通知）を実装済み
- 形態: macOS 26 以上のメニューバー常駐アプリ（NSStatusItem ＋ NSPanel、中身は SwiftUI）

## 入手と更新

最初のリリースを出したら、[GitHub Releases](https://github.com/Junpeiwada/JPAgentManager/releases) から `JPAgentManager-<版>.zip` をダウンロードして展開し、`JPAgentManager.app` を置いて開く（Developer ID 署名・公証済み）。まだリリースは出していない。

以後は Sparkle による自動更新で、24 時間ごとに確認する。手動で確認するには、パネルのフッター（版数の横）の「更新を確認…」か、メニューバーのアイコンを右クリック（control＋クリック）して「更新を確認…」を選ぶ。

リリースの出し方は [Docs/リリース手順.md](Docs/リリース手順.md)。

## 文書

| ファイル | 内容 |
|---|---|
| [Docs/要求仕様.md](Docs/要求仕様.md) | 要求仕様（P1: 1台で完結 / P2: マシン横断） |
| [Docs/設計メモ.md](Docs/設計メモ.md) | 形態の検討経緯、データ取得元の実測メモ |
| [Docs/リリース手順.md](Docs/リリース手順.md) | 署名・公証・自動更新つきのリリース手順 |
| [Docs/実装計画-自動更新.md](Docs/実装計画-自動更新.md) | 自動更新（Sparkle）とリリースの仕組みの実装計画 |
| [Docs/図/案1-メニューバー.svg](Docs/図/案1-メニューバー.svg) | ドロップダウンの画面図 |

経緯: 別リポジトリで検討したものを、2026-10-30 にこのリポジトリへ移した。

## ライセンス

[MIT](LICENSE)
