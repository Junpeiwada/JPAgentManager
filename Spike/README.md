# Spike: フック記録と前面化の手動検証

**結論**: 検証用リポジトリ `~/Documents/Project/_jpam-spike/` を VSCode で開き、Claude Code のタブで下の ①〜⑦ を順に行うと、全フックの入力が `~/Library/Logs/jpam-spike/hooks.jsonl` に1行ずつ溜まる。各場面のあとに記録を見て、記録欄の表に書き込む。

フックは検証用リポジトリの `.claude/settings.local.json` にだけ登録済みで、`~/.claude/settings.json` には触れていない。記録スクリプトは [record-hook.sh](record-hook.sh)（常に終了コード 0、標準出力なし）。

## 確かめたいこと

- (a) 許可待ちの Notification と、60秒入力が無いときの Notification を、入力（`message` や `notification_type`）で見分けられるか
- (b) 許可したあと PreToolUse / PostToolUse が来るか
- (c) 拒否や Esc 中断で Stop が来るか
- (d) フックの親をたどって `claude` プロセス（`…/anthropic.claude-code-*/resources/native-binary/claude`）の PID に着くか

## 準備

1. VSCode で `~/Documents/Project/_jpam-spike/` を開く
2. 記録を空にして始める（任意）: `rm -f ~/Library/Logs/jpam-spike/hooks.jsonl`
3. 見やすい表示用に、以下のコマンドを使う（`jq` が入っていなければ `python3` の方）

```sh
# イベント名と入力の要点だけ一覧
python3 -I -c '
import json,os
for l in open(os.path.expanduser("~/Library/Logs/jpam-spike/hooks.jsonl")):
    r=json.loads(l); i=r["input"]
    print(r["ts"], r["event"], {k:v for k,v in i.items() if k not in ("transcript_path","cwd")} if isinstance(i,dict) else i)
'
# 生のまま末尾を見る
tail -n 5 ~/Library/Logs/jpam-spike/hooks.jsonl
# claude プロセスに着いているか（chain の中に native-binary/claude があるか）
grep -c 'native-binary/claude' ~/Library/Logs/jpam-spike/hooks.jsonl
```

## 手順（Claude Code のタブで）

各場面の前に、記録の行数を控えておくと差分が分かる: `wc -l ~/Library/Logs/jpam-spike/hooks.jsonl`

| # | 場面 | やること | 見るコマンド |
|---|------|----------|--------------|
| ① | 新しいタブ | Claude Code のタブを新しく開く。何も送らない | `tail -n 3 ~/Library/Logs/jpam-spike/hooks.jsonl` |
| ② | 指示を送る | 「こんにちは」など、ツールを使わない質問を送る | `tail -n 4 ~/Library/Logs/jpam-spike/hooks.jsonl` |
| ③ | 許可して実行 | 「sample.txt の末尾に1行足して」と送り、許可を求められたら許可する | `tail -n 8 ~/Library/Logs/jpam-spike/hooks.jsonl` |
| ④ | 拒否 | 同じ依頼を送り、許可を求められたら拒否する | `tail -n 8 ~/Library/Logs/jpam-spike/hooks.jsonl` |
| ⑤ | Esc で中断 | 「sleep 30 を実行して」と送り、実行中に Esc で中断する | `tail -n 6 ~/Library/Logs/jpam-spike/hooks.jsonl` |
| ⑥ | 60秒放置 | 返答が終わったあと、何もせず60秒以上待つ | `tail -n 3 ~/Library/Logs/jpam-spike/hooks.jsonl` |
| ⑦ | タブを閉じる | タブを閉じる（窓は閉じない） | `tail -n 3 ~/Library/Logs/jpam-spike/hooks.jsonl` |

注意: ⑥は Notification が来ない場合もある。来なければ「来なかった」と書く。

## 記録欄: フック（P1-2 / P1-3）

結果を書き込む。「来た」「来ない」と、判断に使えそうなフィールド名を書く。

| # | 場面 | 来たイベント（順） | Notification の `message` / `notification_type` | Stop は来たか | chain は claude に着いたか | メモ |
|---|------|-------------------|-----------------------------------------------|---------------|----------------------------|------|
| ① | 新しいタブ | | | | | |
| ② | 指示を送る | | | | | |
| ③ | 許可して実行 | | | | | |
| ④ | 拒否 | | | | | |
| ⑤ | Esc で中断 | | | | | |
| ⑥ | 60秒放置 | | | | | |
| ⑦ | タブを閉じる | | | | | |

確認事項のまとめ:

| 項目 | 結果 |
|------|------|
| (a) 許可待ちと60秒放置の Notification を入力で見分けられるか | |
| (b) 許可後に PreToolUse / PostToolUse が来るか | |
| (c) 拒否・Esc 中断で Stop が来るか | |
| (d) chain をたどって claude の PID に着くか（そのタブの `session_id` との対応も） | |

### P1-3: 実行時間（実施済みの目安）

サンプル入力を20回流した計測: `elapsed_ms` は平均 約32ms、最大 約40ms（50ms 以内）。実際のフックでの値は次で見る。

```sh
python3 -I -c '
import json,os
e=[json.loads(l)["elapsed_ms"] for l in open(os.path.expanduser("~/Library/Logs/jpam-spike/hooks.jsonl"))]
print(len(e), sum(e)/len(e), max(e))'
```

## 前面化の手動検証（P1-4）

`<id>` は、記録の `session_id`（`tail` で確認）を使う。

| # | 確かめること | 手順 | 結果 |
|---|--------------|------|------|
| 1 | `code` をフルパスで呼ぶと既存の窓が前に出るか | 別のアプリを前面にして、`"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ~/Documents/Project/_jpam-spike` を実行する。新しい窓が開くか、既存の窓が前に出るかを見る | |
| 2 | URI はどの窓に届くか | 窓を2つ開いた状態（別フォルダ）で、`open "vscode://anthropic.claude-code/open?session=<id>"` を実行する。どちらの窓が反応するか | |
| 3 | 既存タブを開くか、新しいタブを作るか | そのセッションのタブが開いている状態で #2 を実行する。タブが増えるか、既存タブに移るか。タブを閉じた状態でも試す | |
| 4 | 同じフォルダを2窓で開いたとき | 同じフォルダを2つの窓で開き、`code` のフルパス呼び出しと #2 の URI を試す。どちらの窓が前に出るか | |

## メニューバー試作で確かめる項目

[MenuBarSpike/README.md](MenuBarSpike/README.md)（別の実装役が作成。ビルド方法と確かめる項目はそちら）を見る。
