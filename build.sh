#!/bin/zsh
# NoSleep.app をビルドして ~/Applications にインストールする
set -e

SRC_DIR="${0:A:h}"
APP_NAME="NoSleep"
DEST="$HOME/Applications/${APP_NAME}.app"
BUILD="$SRC_DIR/build/${APP_NAME}.app"

rm -rf "$SRC_DIR/build"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"

echo "==> コンパイル"
swiftc -O \
  -target arm64-apple-macos14.0 \
  -o "$BUILD/Contents/MacOS/${APP_NAME}" \
  "$SRC_DIR/main.swift"

echo "==> Info.plist"
cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>NoSleep</string>
  <key>CFBundleDisplayName</key>     <string>NoSleep</string>
  <key>CFBundleExecutable</key>      <string>NoSleep</string>
  <key>CFBundleIdentifier</key>      <string>local.nosleep.NoSleep</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHumanReadableCopyright</key><string>ローカルビルド</string>
</dict>
</plist>
PLIST

echo "==> 署名 (ad-hoc)"
codesign --force --sign - "$BUILD"

echo "==> インストール: $DEST"
# 起動中なら先に終了させる
pkill -x "$APP_NAME" 2>/dev/null || true
# ログイン項目(BTM)の登録はアプリのパスに紐づくため、バンドルごと削除せず
# 上書き更新する。rm -rf すると「ログイン時に起動」が外れることがある。
mkdir -p "$DEST"
ditto "$BUILD" "$DEST"

echo "==> 完了"
codesign -dv "$DEST" 2>&1 | sed -n '1,3p'
