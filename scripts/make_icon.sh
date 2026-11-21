#!/bin/bash
# 生成 Support/AppIcon.icns（用 scripts/make_icon.swift 画 1024 底图，再切各尺寸打包）
set -euo pipefail

cd "$(dirname "$0")/.."

MASTER="${TMPDIR:-/tmp}/winexplorer-icon-1024.png"
ICONSET="build/AppIcon.iconset"

echo "==> 绘制 1024 图标"
if command -v swift >/dev/null 2>&1; then
	swift scripts/make_icon.swift "$MASTER"
else
	echo "!! 找不到 swift，无法生成图标" >&2
	exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> 切各尺寸"
for size in 16 32 128 256 512; do
	sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
	double=$((size * 2))
	sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

echo "==> 打包 icns"
iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
echo "==> 完成: $(pwd)/Support/AppIcon.icns"
