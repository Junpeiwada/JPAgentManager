# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

複数の Mac・複数のリポジトリの Claude Code を一覧する macOS メニューバーアプリ。要求は [Docs/要求仕様.md](Docs/要求仕様.md) が正本。

## ルール

- 日本語で応答する
- コミットはユーザーの指示があったときだけ行う。メッセージは日本語で、Co-Authored-By は付けない
- GitHub リモート（origin）がある。push はユーザーの指示があったときだけ行う
- `~/.claude/` 配下のログ・設定は**読むだけ**。書き換えるのはフックの登録だけで、ユーザーの了承を得てから行う

## 文書

- [Docs/要求仕様.md](Docs/要求仕様.md): 機能要求（FR-xxx）、非機能要求、未検証の前提（§8）
- [Docs/設計メモ.md](Docs/設計メモ.md): 形態の検討経緯と実測メモ
- [Docs/実装計画-P1.md](Docs/実装計画-P1.md): P1 のフェーズと進捗（更新は impl-plan スキルの手順で）。「注意点」に実測で分かった制約がある
- [Docs/実装計画-自動更新.md](Docs/実装計画-自動更新.md): Sparkle による自動更新とリリースの仕組みのフェーズと進捗
- [Docs/リリース手順.md](Docs/リリース手順.md): 一度だけの準備（鍵・Secrets・Pages）、毎回のリリース手順、つまずきやすい点

## ビルドとテスト

`.xcodeproj` は XcodeGen の生成物で git 管理していない。`project.yml` を変えたとき・ファイルを足したときは `xcodegen generate` からやり直す。

```sh
xcodegen generate
xcodebuild -scheme JPAgentManager -destination 'platform=macOS' build test 2>&1 | tail -3
# 1クラスだけ
xcodebuild -scheme JPAgentManager -destination 'platform=macOS' test -only-testing:JPAgentManagerTests/SortingTests
# アイコンを作り直す（Design/AppIcon.svg → App/Assets.xcassets）
./Scripts/make-appicon.sh
```

- macOS 26 以上、サンドボックスなし・アドホック署名
- ハードンドランタイムは `project.yml` では全構成 NO。公証に必須なので、CI の `xcodebuild archive` にコマンドラインで `ENABLE_HARDENED_RUNTIME=YES` を渡して付ける（アドホック署名のまま有効にすると Sparkle を読めず起動しない）
- リリースは `Scripts/release.sh <版>`（例 `0.1.1`、`-y` で確認省略）。`project.yml` の `MARKETING_VERSION` を上げてコミット→タグ `v<版>`→今いるブランチとタグを push すると、CI（`.github/workflows/release.yml`）が署名・公証・GitHub Release・appcast（GitHub Pages）の更新まで行う。配布物の版は CI がタグ（`v` を外した値）で `MARKETING_VERSION` を上書きして決まる（`project.yml` の値は手元の記録用）。手動実行では入力した版でタグがビルドしたコミットに作られる。準備と手順は [Docs/リリース手順.md](Docs/リリース手順.md)
- `package.json` は VSCode の NPM SCRIPTS パネルから実行するためだけに置いている（npm の依存はない）。`release`（引数なしなら版を対話で尋ねる）・`generate`・`build`・`test`・`run`・`sample`。`build`/`test` の出力先は `build/`
- アプリを `--sample` 付きで起動すると、実データを読まずにサンプルデータ（`App/Model/SampleData.swift`）で表示する。見た目の確認用
- テストは `TEST_HOST` でアプリ本体に載せて動く。`AppDelegate` は XCTest 中は何も作らない
- `Spike/` はフェーズ1の検証用の使い捨てで、製品のビルドには入らない

## 構成

ターゲットは3つ: アプリ `JPAgentManager`、フック用の補助プログラム `jpam-hook`（`HookHelper/`。アプリには同梱せず、テストのためだけにビルドされる）、テスト `JPAgentManagerTests`。

データの流れ（アプリが書き込むのは `git fetch` によるリモート追跡ブランチの更新だけ）:

1. `SessionStore`（`App/Model/`）が 1 秒ごと＋sessions フォルダの監視で `refresh()` する。重い読み込みは背景キュー、結果の反映はメインスレッド
2. 状態は `SessionRegistry` が `~/.claude/sessions/<PID>.json` から読む（busy / idle / waiting）。生きている PID だけを残す
3. タイトル・直前の操作・最後のプロンプトは `TranscriptReader` が会話ログ（jsonl）から読む
4. リポジトリのまとまりとブランチは `GitInfo`。遅いので別キューで非同期に取り、30 秒キャッシュする。コミット差・変更ファイル数は `GitStatusReader` で、開いているリポジトリの status を 30 秒ごと、`git fetch` を 5 分ごと（失敗後は 15 分後）に行う。fetch は認証の入力を求めず、`FETCH_HEAD` も書かない
5. `SessionStore.build`（純粋関数）が突き合わせて `[Repo]` を作り、`Sorting` で並べる。テストはここを直接叩く
6. `AppDelegate` が `@Published repos` を `PanelModel`（表示）と `Notifier`（状態変化からの通知）へ流す

画面は SwiftUI の `MenuBarExtra` ではなく `NSStatusItem`（`StatusItemController`、件数を描いた画像）＋`NSPanel`（`PanelController`）。中身の SwiftUI は `App/Views/`。

前面化（`Focuser`）は VSCode のセッション（`entrypoint == "claude-vscode"`）だけ。`code` CLI をフルパスで呼んで作業フォルダの窓を前に出す（タブまでは選べない）。CLI セッションは対象外。

`App/Setup/HookInstaller.swift`・`App/Sources/HookEventReader.swift`・`App/Sources/ProcessScanner.swift` と `HookHelper/` は、状態の取得元をフックから sessions ファイルに切り替える前の実装で、いまのアプリからは呼ばれていない（テストだけ残っている）。`jpam-hook` はアプリに同梱しないので、テストはビルド成果物の置き場所（アプリと同じフォルダ）から読む。

自動更新は Sparkle（2.9.3 に固定、`exactVersion`。上げるときは `project.yml` と release.yml の `generate_appcast` の版を一緒に上げる。実装は `App/Actions/UpdaterController.swift`）。`App/Info.plist` の `SUFeedURL`（GitHub Pages の `appcast.xml`）・`SUPublicEDKey` で更新を受け、24 時間ごとに自動確認する（Debug では `SPUUpdaterDelegate` の `mayPerform` が背景の確認だけを止める。設定値は書き換えず、配布版には影響しない。手動は可）。手動の「更新を確認…」はパネルのフッターとメニューバーアイコンの右クリックメニューにある。鍵は JPAgentManager 専用でログインキーチェーンの account `JPAgentManager`。

## 前提にしている非公開の形式

`~/.claude/sessions/<PID>.json` の中身、会話ログの `ai-title`・`last-prompt` は公開仕様ではない。読めない・形が変わったときは「状態不明」「—」を出して落ちないことを守り、その振る舞いはテスト（`Tests/Fixtures/` の壊れたログなど）で押さえている。
