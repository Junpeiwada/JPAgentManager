# MenuBarSpike (P1-5)

NSStatusItem + NSPanel(中身は SwiftUI の NSHostingView)で、MenuBarExtra の懸念点を回避できるかを確かめる試作。

## ビルドと起動

```bash
bash Spike/MenuBarSpike/build.sh
Spike/MenuBarSpike/build/MenuBarSpike              # .glassEffect
Spike/MenuBarSpike/build/MenuBarSpike --material   # .regularMaterial に切り替え
```

終了はターミナルで Ctrl-C、または `pkill MenuBarSpike`。Dock には出ない。行をクリックすると標準出力に `clicked: <タイトル>` が出る。

## 確認チェックリスト

- [ ] メニューバーに橙の点+1、青の点+2、/ 8 がカラーで出る(白黒になっていない)
- [ ] ライトのメニューバーで数字が読める
- [ ] ダークのメニューバー(壁紙を暗くする、または外観をダークにする)で数字が読める
- [ ] クリックでパネルがステータスアイテムの真下に開き、もう一度クリックで閉じる
- [ ] パネル背景に Liquid Glass が効いている(背後の壁紙が透けてぼける)
- [ ] 「行を足す」で高さが中身に合わせて伸び、「行を減らす」で縮む(上端は動かない)
- [ ] 行を足し続けると上限(560pt)で止まり、スクロールになる
- [ ] 行をクリックすると標準出力に `clicked: ...` が出てパネルが閉じる
- [ ] パネルの外(他アプリ・デスクトップ)をクリックすると閉じる
- [ ] Esc で閉じる
- [ ] ダークモードでパネル・フォルダ・カプセルの見え方に問題がない
- [ ] `--material` と見た目を比較する(ガラスとの差、可読性)
- [ ] 他アプリが前面のまま開閉できる(アプリが前面化・フォーカスを奪わない)

## 記録欄

| 項目 | 結果 | メモ |
|---|---|---|
| カラーの点 | | |
| ライト/ダークの数字 | | |
| .glassEffect | | |
| --material | | |
| 高さの追従/スクロール | | |
| 行・外側・Esc で閉じる | | |
| 気づいたこと | | |
