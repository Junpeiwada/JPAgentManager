# P1-6 結果: libproc による claude プロセス監視

実行環境: macOS 27.0.1 / Swift 6.4 / arm64。ビルドは `bash Spike/ProcScan/build.sh`、実行は `build/ProcScan`（`--loop <秒>`、`--interval <秒>`）。

## 結論

- libproc だけで「claude の PID・作業フォルダ・親 PID・親のパス・起動時刻」が取れ、`ps` / `lsof` と完全に一致した。
- 2秒ごとの監視の CPU 使用率は **0.25%（60秒計測）で、1% 未満**。1回の走査は全 PID（約700）込みで平均5ms。
- 権限で取れないものは無かった（同一ユーザーの claude のみを対象にしたため。他ユーザーのプロセスは未検証）。

## 1回実行の結果（6 件検出）

| claude PID | 親 PID（Code Helper (Plugin)） | 作業フォルダ |
|---|---|---|
| 3216 | 7025 | SoundKit |
| 15521 | 80648 | Viewer |
| 80908 | 80648 | Viewer |
| 31017 | 30635 | JPAgentManager |
| 58110 | 7578 | SensorDemo |
| 59008 | 15368 | KeyLab |

- 親はすべて `Code Helper (Plugin)`（拡張ホスト）だった。
- **同じ窓の claude は同じ親を持つ**: Viewer の2タブ（15521 と 80908）は親が共に 80648。窓ごとに拡張ホストが1つで、タブ数 = その親を持つ claude の数と判定できる。
- 起動時刻（`pbi_start_tvsec`）も取れた（例: 3216 は 15:54:03）。

## ps / lsof との比較

- `ps -axo pid,ppid,comm | grep native-binary/claude` の (pid, ppid) 6 組が、ProcScan と全件一致。
- `lsof -a -d cwd -p <pid>` の作業フォルダは、取れた5件が全件一致。31017 は `pgrep -f` に出ず lsof を回していないが、ProcScan では JPAgentManager（この作業ツリー）で整合する。

## --loop 60（2秒間隔・30回）

```
[初回] 6 件: 3216,15521,31017,58110,59008,80908
経過 60.3s / CPU 0.152s / CPU使用率 0.252% / スキャン 30回 平均 5.25ms 最大 8.58ms
```

- 途中で増減は無かった。別の試行（修正前のバグ版で6件中2件しか見ていなかった状態）では、60秒の間に現れて消えるプロセス（pid 65885、約18秒）を増/消として検出できており、差分検出自体は動く。
- 全 PID を毎回走査する方式なので、PID 数に比例する。約700 PID で上記の値。

## 引き継ぎ注意点（本実装の ProcessScanner へ）

1. **`proc_listallpids` の戻り値は「個数」**。`proc_listpids` はバイト数だが、`proc_listallpids(nil, 0)` も `proc_listallpids(buf, size)` も個数で返る（macOS 27 で確認）。バイト数として `/4` すると約1/4しか読めず、claude を取り逃がす（最初にこれで 6 件中 2 件しか出なかった）。バッファは `個数 + 256` 程度の余裕を持たせ、`size` 引数はバイト数で渡す。
2. 構造体のサイズは `MemoryLayout<proc_bsdinfo>.size` / `MemoryLayout<proc_vnodepathinfo>.size` を `proc_pidinfo` の `buffersize` に渡し、**戻り値がそのサイズと等しいか**で成否を判定する（失敗は 0 や -1）。
3. 作業フォルダは `proc_vnodepathinfo.pvi_cdir.vip_path`。固定長 C 配列（タプル）なので `withUnsafePointer` + `withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN))` で `String(cString:)` にする。
4. `proc_pidpath` のバッファは `4 * MAXPATHLEN`（`PROC_PIDPATHINFO_MAXSIZE` マクロは Swift に出ないので自前で定義）。
5. `proc_name` は `claude` を返すが、パスの方が確実。`…/native-binary/claude` で終わるものを VSCode 版、それ以外で末尾が `claude` のものを CLI 版として分けた。**CLI 版は実機に無く未検証**。
6. 親が拡張ホストかは親の `proc_pidpath` に `Code Helper (Plugin)` を含むかで判定できる。ただしこのエージェント自身のようにアプリ外から SDK 経由で動く claude（例: pid 65832/65885）は親が拡張ホストではなく、native-binary/claude に一致してしまう。タブ数に数えないよう、**親が拡張ホストのものだけをタブとして数える**こと。
7. 閉じたタブの判定は、前回の PID 集合との差分（消えた PID）で取れる。PID 再利用に備え、PID と起動時刻の組をキーにすると安全。
8. 他ユーザーのプロセス、サンドボックス下のアプリからの取得可否は未検証（本実装がサンドボックスなら `proc_pidinfo` が失敗しうる。要確認）。
