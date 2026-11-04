#!/bin/bash
# Claude Code のフック入力と親プロセスの連なりを 1 行の JSON で追記する検証用スクリプト。
# 使い方: record-hook.sh <イベント名>   （フック入力の JSON は stdin から受け取る）
# 記録先: $JPAM_SPIKE_LOG、無ければ ~/Library/Logs/jpam-spike/hooks.jsonl
# どんなエラーでも終了コード 0、stdout には何も出さない（Claude Code の動作を妨げないため）。
# 標準コマンド（bash / ps / awk / perl / tr / sed）だけを使う。

main() {
  local event="${1:-unknown}"
  local log="${JPAM_SPIKE_LOG:-$HOME/Library/Logs/jpam-spike/hooks.jsonl}"
  mkdir -p "$(dirname "$log")" || return 0

  local t0 t1 input chain
  t0=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')

  # stdin をそのまま受け取り、改行を除去して 1 行にする
  input=$(cat | tr -d '\r\n')
  # JSON オブジェクトでなければ、文字列として包む（行全体を壊さないため）
  case "$input" in
    "{"*"}") ;;
    *) input="\"$(printf '%s' "$input" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\"" ;;
  esac

  # 自分から launchd 手前までの連なり。ps は 1 回だけ呼び（遅いため）、awk でたどる。
  chain=$(
    /bin/ps -axo pid=,ppid=,args= |
    /usr/bin/awk -v start="$$" '
      function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s); return s }
      {
        pid = $1; ppid[pid] = $2
        r = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", r)
        # ps の comm は 16 文字で切れるため使わず、args の先頭の語を comm とする（全体は args に入る）
        c = r; sub(/ .*/, "", c)
        comm[pid] = c; args[pid] = r
      }
      END {
        p = start + 0; out = ""; n = 0
        while (p > 1 && (p in ppid) && n < 64) {
          item = sprintf("{\"pid\":%d,\"ppid\":%d,\"comm\":\"%s\",\"args\":\"%s\"}", p, ppid[p], esc(comm[p]), esc(args[p]))
          out = out (out == "" ? "" : ",") item
          p = ppid[p] + 0; n++
        }
        printf "%s", out
      }'
  )

  t1=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
  local elapsed
  elapsed=$(/usr/bin/awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", (b - a) * 1000 }')

  printf '{"ts":%s,"event":"%s","input":%s,"chain":[%s],"elapsed_ms":%s}\n' \
    "$t0" "$event" "${input:-null}" "$chain" "$elapsed" >> "$log"
}

main "$@" >/dev/null 2>&1
exit 0
