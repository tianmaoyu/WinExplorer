#!/bin/bash
# 打包成 .pkg（装到 /Applications）
# 产物: build/WinExplorer-<版本>.pkg
# 注意：没有开发者证书，装出来是未签名包，首次运行仍会被 Gatekeeper 拦一次（右键「打开」可绕过）。
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
APP="build/WinExplorer.app"
PKG="build/WinExplorer-$VERSION.pkg"

if [ ! -d "$APP" ] || [ "${1:-}" = "--rebuild" ]; then
	echo "==> 构建 App"
	./scripts/build_app.sh release
fi

echo "==> 生成 PKG"
rm -f "$PKG"
pkgbuild \
	--component "$APP" \
	--install-location /Applications \
	--identifier com.eric.winexplorer \
	--version "$VERSION" \
	"$PKG"

echo "==> 完成: $(pwd)/$PKG"
ls -lh "$PKG"
