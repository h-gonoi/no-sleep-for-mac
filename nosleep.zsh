# ---- nosleep : 指定した時間だけスリープを防ぐ ----
# 使い方 : nosleep [時間]   例) nosleep 2  -> 2時間
# 引数省略時は 1 時間。整数(1以上)以外なら使い方を表示し、電源設定は変更しない。
# 通常終了 / Ctrl-C のどちらでも必ず `pmset -a disablesleep 0` に戻す。
#
# 導入 : ~/.zshrc に次の 1 行を追記して、シェルを開き直す
#   [[ -r /path/to/nosleep.zsh ]] && source /path/to/nosleep.zsh
#   （存在チェックを前置するのは、ファイルを移動したときにシェル起動のたび
#     エラーが出るのを防ぐため）

_nosleep_restore() {
  # INT トラップの後に EXIT トラップも走るため、二重実行を防ぐ
  [[ -n $_NOSLEEP_RESTORED ]] && return 0
  _NOSLEEP_RESTORED=1
  if sudo pmset -a disablesleep 0; then
    print -- "[nosleep] スリープ抑止を解除しました (disablesleep 0)"
  else
    print -u2 -- "[nosleep] 警告: 解除に失敗しました。手動で実行してください:"
    print -u2 -- "          sudo pmset -a disablesleep 0"
  fi
}

nosleep() {
  emulate -L zsh
  setopt local_traps

  local hours="${1:-1}"

  # 引数チェック: 1つだけ、かつ 1 以上の整数 (<1-> は zsh の数値グロブ)
  if [[ $# -gt 1 ]] || [[ $hours != <1-> ]]; then
    print -u2 -- "使い方: nosleep [時間]"
    print -u2 -- "  時間 : 1 以上の整数（単位=時間）。省略時は 1。"
    print -u2 -- "  例   : nosleep     -> 1時間スリープを防ぐ"
    print -u2 -- "         nosleep 2   -> 2時間スリープを防ぐ"
    print -u2 -- "電源設定は変更していません。"
    return 2
  fi

  local secs=$(( hours * 3600 ))

  print -- "[nosleep] ${hours}時間 (${secs}秒) スリープを抑止します。"
  print -- "[nosleep] 管理者パスワードを求められたら、このターミナルに直接入力してください。"

  if ! sudo pmset -a disablesleep 1; then
    print -u2 -- "[nosleep] エラー: pmset -a disablesleep 1 に失敗しました。電源設定は変更していません。"
    return 1
  fi

  # ここから先はどの終わり方でも必ず解除する
  _NOSLEEP_RESTORED=
  trap '_nosleep_restore; return 130' INT
  trap '_nosleep_restore; return 143' TERM
  trap '_nosleep_restore' EXIT

  print -- "[nosleep] 開始しました。途中でやめるときは Ctrl-C。"
  # -d 画面 / -i アイドル / -m ディスク / -s システム / -u ユーザー活動
  caffeinate -dimsu -t "$secs"
}
