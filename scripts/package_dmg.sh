#!/bin/bash
# 打包成 DMG（拖进「应用程序」安装）
# 产物: build/WinExplorer-<版本>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
APP="build/WinExplorer.app"
DMG="build/WinExplorer-$VERSION.dmg"

if [ ! -d "$APP" ] || [ "${1:-}" = "--rebuild" ]; then
	echo "==> 构建 App"
	./scripts/build_app.sh release
fi

STAGE="$(mktemp -d)/WinExplorer"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> 生成 DMG"
rm -f "$DMG"
hdiutil create \
	-volname "WinExplorer" \
	-srcfolder "$STAGE" \
	-ov -format UDZO \
	"$DMG" >/dev/null

echo "==> 完成: $(pwd)/$DMG"
ls -lh "$DMG"
