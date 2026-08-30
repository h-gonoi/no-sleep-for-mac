# NoSleep — Claude Code 向けメモ

macOS のスリープを一時的に止めるツール。メニューバーアプリ（Swift 単一ファイル）と
zsh 関数（`nosleep` コマンド）の 2 系統。どちらも `pmset -a disablesleep` と
`caffeinate` を叩くだけで、外部依存はない。

## ファイル構成

| ファイル | 役割 |
|---|---|
| `main.swift` | メニューバーアプリ本体（単一ファイル。分割しない） |
| `build.sh` | `swiftc` でビルド → Info.plist 生成 → ad-hoc 署名 → `~/Applications/NoSleep.app` へ設置 |
| `nosleep.zsh` | `nosleep` シェル関数。`.zshrc` から `source` して使う |
| `README.md` | 利用者向けドキュメント（日本語） |

パッケージマネージャも Xcode プロジェクトも使わない。ビルドは `build.sh` だけ。

## セットアップ（clone 直後にこれを実行する）

ユーザーから「セットアップして」と言われたら、以下を上から順に実行する。
**`sudo` や `.zshrc` への追記を伴うステップは、実行前に必ずユーザーに確認を取る。**

### 0. 前提の確認

```sh
sw_vers -productVersion          # 14.0 以上であること（SMAppService を使うため）
xcode-select -p                  # 失敗するなら CLT 未導入
swiftc --version                 # コンパイラの有無
```

`xcode-select -p` が失敗する場合、Xcode Command Line Tools が必要。
インストールは GUI ダイアログを伴うため Claude Code からは完了まで面倒を見られない。
ユーザーに `xcode-select --install` を自分で実行してもらい、完了後に再開する。

### 1. メニューバーアプリのビルドとインストール

```sh
zsh build.sh
```

`~/Applications/NoSleep.app` に入る。`build.sh` はリポジトリの位置を `${0:A:h}` で
解決するので、clone 先はどこでもよい。`uname -m` からターゲットを決めるので
Apple Silicon / Intel の両方でビルドできる（ビルドしたマシン用の 1 アーキテクチャのみ）。

起動:

```sh
open ~/Applications/NoSleep.app
```

メニューバーに 🌙 が出れば成功。`LSUIElement = true` なので Dock には出ない。

### 2. `nosleep` コマンド（任意 / GUI と併用しない）

**GUI とコマンドは同時に使わない。** どちらも同じ `pmset -a disablesleep` を操作するため、
片方の解除処理がもう片方の抑止まで解いてしまう。ユーザーがどちらを使うか決めてから入れる。

`.zshrc` を編集する前にバックアップを取る:

```sh
cp ~/.zshrc ~/.zshrc.backup.$(date +%Y%m%d-%H%M%S)
echo "[[ -r $PWD/nosleep.zsh ]] && source $PWD/nosleep.zsh" >> ~/.zshrc
```

**必ずリポジトリのルートで実行すること。** `$PWD` は追記の時点で展開されるので、
`.zshrc` に書き込まれるのは絶対パスになる。存在チェックを前置しているのは、
あとでリポジトリを移動・削除したときに新しいシェルを開くたび
`no such file or directory` が出るのを防ぐため。
反映は新しいシェルを開くか `source ~/.zshrc`。

### 3. 動作確認

インストール直後の状態は「抑止していない」= `SleepDisabled 0` であるべき。

```sh
pmset -g | grep SleepDisabled
```

## 作業するときの注意

- **動作確認に副作用がある。** `pmset -a disablesleep 1` は実際に PC のスリープを止め、
  再起動をまたいで残る。検証で 1 にしたら、必ず `sudo pmset -a disablesleep 0` に戻す。
- **認証は毎回出る。** `sudo` のキャッシュは既定 5 分。オン/オフ双方でパスワードを求められるのは仕様。
- **`build.sh` は `~/Applications/NoSleep.app` を `rm -rf` しない**（`ditto` で上書き）。
  ログイン項目（BTM）の登録がアプリのパスに紐づいており、バンドルを消すと
  「ログイン時に起動」が外れるため。ここを `rm -rf` + `cp` に書き換えないこと。
- **オン/オフの順序を入れ替えない。** 権限が要る `pmset` を先に実行し、成功したときだけ
  `caffeinate` を起動する。逆順だと認証キャンセル時に `caffeinate` だけが残る。
- **ドキュメントは日本語**。README も本ファイルもコード内コメントも日本語で統一する。
- **`build/` は Git 管理外**（`.gitignore` 済み）。

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `swiftc: command not found` | `xcode-select --install` をユーザーに依頼 |
| ビルドは通るがメニューバーに出ない | `pgrep -x NoSleep` で起動確認。`LSUIElement` により Dock には出ないのが正常 |
| スリープ抑止が解除できない | `sudo pmset -a disablesleep 0` を手動実行 |
| 「ログイン時に起動」が勝手に外れる | `build.sh` が `$DEST` を削除していないか確認 |
