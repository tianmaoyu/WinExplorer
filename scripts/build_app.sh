#!/bin/bash
# 构建 WinExplorer.app（SwiftPM + 手工组装 .app bundle）
# 用法: ./scripts/build_app.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."

# 本机 xcode-select 指向 CommandLineTools，其 PackageDescription 与 swiftpm 不匹配，
# 因此优先切换到完整 Xcode 工具链。
XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1 || true)"
if [ -n "${XCODE_APP:-}" ]; then
	export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
	export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
fi

CONFIG="${1:-release}"
APP_DIR="build/WinExplorer.app"

echo "==> swift build -c $CONFIG"
# --disable-sandbox: SwiftPM 的 sandbox-exec 在受限环境里会报 Operation not permitted
swift build -c "$CONFIG" --disable-sandbox

BIN_PATH="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)/WinExplorer"
if [ ! -f "$BIN_PATH" ]; then
	echo "!! 未找到可执行文件: $BIN_PATH" >&2
	exit 1
fi

echo "==> 组装 $APP_DIR"
if [ -d "$APP_DIR" ]; then
	mv "$APP_DIR" "/tmp/WinExplorer.app.$(date +%s).bak"
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/WinExplorer"
cp Support/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# ad-hoc 签名，让 TCC 权限（桌面/文稿访问）在多次构建间保持稳定
codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 || \
	echo "   (ad-hoc 签名失败，忽略)"

echo "==> 完成: $(pwd)/$APP_DIR"
